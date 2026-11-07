#+build !wasi
package conn

import "core:strings"
import "core:sync"
import "core:thread"

import "client:audio"
import "common:memtrack"

// Where a connection goes and what it does first, as client_open and the
// conversation commands take it.
Net_Target :: struct {
	key_path:      string,
	server:        string,
	password:      string,
	known_servers: string,
	// The channel to show and talk in from the start, if any; otherwise the
	// one to only look at.
	channel:       string,
	look_at:       string,
}

// net_run runs a connection on the calling thread: it opens it, goes to the
// conversation `t` asks for and steps it until `stop` is set or the
// connection is over (for example because it was refused). The connection is
// closed on the way out. Both the UI's network thread (client/net_native.odin)
// and Session run it.
net_run :: proc(c: ^Server_Conn, t: Net_Target, stop: ^bool) {
	memtrack.thread_init()
	defer client_close(c)
	if !client_open(c, t.key_path, t.server, t.known_servers, t.password) {
		return
	}
	if t.channel != "" {
		conv_start_in(c, t.channel)
	} else if t.look_at != "" {
		conv_start_viewing(c, t.look_at)
	}
	for !sync.atomic_load(stop) {
		if !client_step(c) {
			return
		}
	}
}

// A connection to one server together with the View it reports to and the
// thread that runs it: what a front end that is not the UI (the terminal
// client) needs. It is reached through `client` (to queue commands with
// push_command) and `view` (to read, holding view.mutex).
Session :: struct {
	client: ^Server_Conn,
	view:   View,
	thread: ^thread.Thread,
	stop:   bool, // set atomically to end the network loop
	target: Net_Target, // owned
}

// session_new makes a session that is ready to start. It has a Voice (the
// protocol code expects one) but opens no audio devices. `wake` is called, from
// whichever thread, when the view has changed.
session_new :: proc(t: Net_Target, wake: proc "c" ()) -> ^Session {
	s := new(Session)
	s.target = {
		key_path      = strings.clone(t.key_path),
		server        = strings.clone(t.server),
		password      = strings.clone(t.password),
		known_servers = strings.clone(t.known_servers),
		channel       = strings.clone(t.channel),
		look_at       = strings.clone(t.look_at),
	}
	view_init(&s.view)
	s.view.wake = wake
	s.view.status = .Connecting
	s.view.server = strings.clone(t.server)
	s.client = new(Server_Conn)
	s.client.view = &s.view
	audio.voice_init(&s.client.voice)
	return s
}

// session_start starts the network thread.
session_start :: proc(s: ^Session) {
	s.thread = thread.create_and_start_with_poly_data(s, session_thread, init_context = context)
}

@(private = "file")
session_thread :: proc(s: ^Session) {
	net_run(s.client, s.target, &s.stop)
}

// session_stop ends the connection (saying goodbye to the server) and waits
// for its thread. It can be called on a session that was never started.
session_stop :: proc(s: ^Session) {
	sync.atomic_store(&s.stop, true)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
}

// session_free stops a session if it is running and frees it.
session_free :: proc(s: ^Session) {
	session_stop(s)
	audio.voice_destroy(&s.client.voice)
	free(s.client)
	view_destroy(&s.view)
	delete(s.target.key_path)
	delete(s.target.server)
	delete(s.target.password)
	delete(s.target.known_servers)
	delete(s.target.channel)
	delete(s.target.look_at)
	free(s)
}
