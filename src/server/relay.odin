package server

import "base:runtime"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:gateway"
import "common:http"
import "common:proto"

// The relay runs alongside the server if the config enables it (see
// config.odin). It lets the web client reach this server.
//
// A browser can't send UDP, so the web client sends its packets over a
// WebSocket instead. The relay converts them back to UDP, using one UDP
// socket per WebSocket, so the server sees each browser as a separate
// client. The relay also serves the web build itself, so a browser only
// needs a single address:
//
//	"relay": { "enabled": true, "port": 8080 }   in config.json
//	open http://localhost:8080/?server=localhost:7777
//
// The media link of a browser (see client/conn/media.odin), which is used
// for the video it watches, works the same way under /yap-media/ but is
// forwarded to the server's media port instead.
//
// The relay can't read what it carries. The session is encrypted end to end
// between the web client and the server, so the relay only sees sealed
// packets. It only relays to this server, regardless of which address the
// page asks for, so it can't be abused to send UDP packets anywhere else.
//
// The bot API (see common/gateway and docs/bot-api) is served on the same
// port under /api/, so that one port, one proxy rule and one certificate
// are enough for both. If the API is enabled but the relay is not, the port
// serves the API and nothing else.

DEFAULT_WEB_DIR :: "web/out"

// How long a UDP read waits before checking whether the WebSocket side
// has gone. This also limits how long a closed connection lingers.
@(private = "file")
UDP_POLL :: 200 * time.Millisecond

// A file that a browser may ask for. The files are read once when the relay
// starts, so after rebuilding the web client the server has to be restarted.
@(private = "file")
Web_File :: struct {
	name:         string,
	content_type: string,
	data:         []u8,
	loaded:       bool, // false if the file couldn't be read
}

@(private = "file")
Relay :: struct {
	listener: net.TCP_Socket,
	server:   net.Endpoint, // the only destination that packets are relayed to
	media:    net.Endpoint, // the server's media port, or port 0 if there is none
	// Whether browsers are relayed and the web client is served. If false,
	// only the API is served.
	web:      bool,
	// Only these files of the web directory are served.
	files:    [9]Web_File,
	api:      ^gateway.Gateway, // nil if the API is disabled
}

// start_relay listens for browsers on `port` in a thread of its own and
// relays them to the server on `server_port` of this machine. Media links
// are relayed to `media_port` unless it is 0. If `web` is false, browsers
// aren't relayed and only the API is served. `api` is the gateway that
// requests under /api/ are handed to, if there is one. It only fails if it
// can't listen. After that it runs for as long as the process does.
start_relay :: proc(
	port: int,
	server_port: int,
	media_port: int,
	web_dir: string,
	web := true,
	api: ^gateway.Gateway = nil,
) -> bool {
	listener, err := net.listen_tcp({net.IP4_Any, port})
	if err != nil {
		log.errorf("could not listen on port %d: %v", port, err)
		return false
	}

	r := new(Relay)
	r.listener = listener
	r.server = {net.IP4_Loopback, server_port}
	r.media = {net.IP4_Loopback, media_port}
	r.web = web
	r.api = api
	r.files = {
		{name = "index.html", content_type = "text/html; charset=utf-8"},
		{name = "index.js", content_type = "text/javascript; charset=utf-8"},
		{name = "index.wasm", content_type = "application/wasm"},
		{name = "favicon.ico", content_type = "image/x-icon"},
		// The files needed to install the web client as an app (see index.html).
		{name = "manifest.webmanifest", content_type = "application/manifest+json"},
		{name = "icon-192.png", content_type = "image/png"},
		{name = "icon-512.png", content_type = "image/png"},
		{name = "apple-touch-icon.png", content_type = "image/png"},
		// The service worker that displays push notifications (push.odin, web/sw.js).
		{name = "sw.js", content_type = "text/javascript; charset=utf-8"},
	}
	for &f in r.files {
		if !web {
			break
		}
		full, _ := filepath.join({web_dir, f.name}, context.temp_allocator)
		data, read_err := os.read_entire_file(full, context.allocator)
		if read_err != nil {
			log.errorf(
				"could not read %s: %v (has the web client been built? see web/build.sh)",
				full,
				read_err,
			)
			continue
		}
		f.data, f.loaded = data, true
	}
	if web {
		log.infof(
			"relaying browsers to udp :%d; serving %s on http://localhost:%d/",
			server_port,
			web_dir,
			port,
		)
	}
	if api != nil {
		log.infof("serving the bot API on http://localhost:%d/api/v1/", port)
	}
	thread.create_and_start_with_poly_data(
		r,
		accept_browsers,
		init_context = context,
		self_cleanup = true,
	)
	return true
}

@(private = "file")
accept_browsers :: proc(r: ^Relay) {
	for {
		free_all(context.temp_allocator)

		sock, from, accept_err := net.accept_tcp(r.listener)
		if accept_err != nil {
			log.warnf("accept failed: %v", accept_err)
			continue
		}
		c := new(http.Conn)
		c.sock, c.remote = sock, from
		log.debugf("connection from %s", net.endpoint_to_string(from, context.temp_allocator))
		thread.create_and_start_with_poly_data2(
			r,
			c,
			handle_connection,
			init_context = context,
			self_cleanup = true,
		)
	}
}

// The temp allocations of a connection thread are only the headers of a
// request and a few strings, so its temp allocator starts small instead of
// with the default 4 MiB.
@(private = "file")
CONNECTION_TEMP :: 16 * 1024

// Each connection thread uses its own temp allocator, which is freed when
// the thread ends:
//
//	temp: runtime.Arena
//	context.temp_allocator = connection_temp_allocator(&temp)
//	defer runtime.arena_destroy(&temp)
//
// The default temp allocator would use a 4 MiB block per thread. That block
// is zeroed and therefore fully resident in memory. core:thread doesn't
// free it for a thread that was started with an init_context, and malloc
// keeps the memory around even after it is freed.
@(private = "file")
connection_temp_allocator :: proc(temp: ^runtime.Arena) -> runtime.Allocator {
	_ = runtime.arena_init(temp, CONNECTION_TEMP, context.allocator)
	return runtime.arena_allocator(temp)
}

@(private = "file")
handle_connection :: proc(r: ^Relay, c: ^http.Conn) {
	temp: runtime.Arena
	context.temp_allocator = connection_temp_allocator(&temp)
	defer runtime.arena_destroy(&temp)
	defer free(c)
	defer net.close(c.sock)

	head, ok := http.read_head(c)
	if !ok {
		return
	}
	// The address may contain the query of the page (?server=...), which
	// parse_request keeps separate from the path.
	req, parsed := http.parse_request(head)
	if !parsed {
		return
	}
	if strings.has_prefix(req.path, gateway.API_PREFIX) {
		if r.api == nil {
			http.respond(
				c.sock,
				"404 Not Found",
				"text/plain",
				"the API is not enabled on this server\n",
			)
			return
		}
		gateway.serve(r.api, c, req)
		return
	}
	if !r.web {
		http.respond(
			c.sock,
			"404 Not Found",
			"text/plain",
			"this server only provides the API, not the web client\n",
		)
		return
	}
	if req.method != "GET" {
		http.respond(
			c.sock,
			"405 Method Not Allowed",
			"text/plain",
			"the yap relay only answers GET\n",
		)
		return
	}
	media := strings.has_prefix(req.path, "/yap-media/")
	if media || strings.has_prefix(req.path, "/yap/") {
		key := http.header(&req, "Sec-WebSocket-Key")
		if !strings.equal_fold(http.header(&req, "Upgrade"), "websocket") || key == "" {
			http.respond(c.sock, "400 Bad Request", "text/plain", "expected a WebSocket upgrade\n")
			return
		}
		if media && r.media.port == 0 {
			http.respond(
				c.sock,
				"404 Not Found",
				"text/plain",
				"the media link is not enabled on this server\n",
			)
			return
		}
		target := req.path[len("/yap-media/" if media else "/yap/"):]
		relay_websocket(r, c, target, key, media)
		return
	}
	serve_file(r, c.sock, req.path)
}

// relay_websocket carries packets between one browser and the server until
// either side disconnects. WebSocket messages are sent on as UDP datagrams
// and UDP datagrams come back as WebSocket messages, one to one. `target`
// is the server address that the page was given. It is only used for the
// log, because the relay always connects to its own server regardless of
// what the page asked for. A `media` link is connected to the server's
// media port.
@(private = "file")
relay_websocket :: proc(r: ^Relay, c: ^http.Conn, target: string, key: string, media: bool) {
	server := r.media if media else r.server
	udp, udp_err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if udp_err != nil {
		log.errorf("could not open a UDP socket: %v", udp_err)
		http.respond(c.sock, "502 Bad Gateway", "text/plain", "could not open a UDP socket\n")
		return
	}
	defer net.close(udp)
	net.set_option(udp, .Receive_Timeout, UDP_POLL)

	accept := strings.concatenate(
		{
			"HTTP/1.1 101 Switching Protocols\r\n",
			"Upgrade: websocket\r\n",
			"Connection: Upgrade\r\n",
			"Sec-WebSocket-Accept: ",
			http.accept_key(key),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !http.send_all(c.sock, transmute([]u8)accept) {
		return
	}
	log.infof(
		"relaying a browser%s (which asked for %s)",
		"'s media link" if media else "",
		target,
	)

	link := Link {
		ws     = c.sock,
		udp    = udp,
		server = server,
	}
	back := thread.create_and_start_with_poly_data(
		&link,
		server_to_browser,
		init_context = context,
	)

	payload: [http.MAX_FRAME]u8
	loop: for !sync.atomic_load(&link.done) {
		op, n, ok := http.read_frame(c, payload[:])
		if !ok {
			break
		}
		#partial switch op {
		case .Binary:
			net.send_udp(udp, payload[:n], server)
		case .Ping:
			sync.guard(&link.write_mutex)
			http.write_frame(c.sock, .Pong, payload[:n])
		case .Close:
			sync.guard(&link.write_mutex)
			http.write_frame(c.sock, .Close, nil)
			break loop
		case .Text, .Pong:
		// The client never sends these, so they are ignored.
		case:
			break loop
		}
	}
	sync.atomic_store(&link.done, true)
	thread.join(back)
	thread.destroy(back)
	log.infof("a browser%s left (which asked for %s)", "'s media link" if media else "", target)
	// This must happen before the socket closes. Anything the server sends
	// to it from now on would only come back as an ICMP "port unreachable".
	// (The session of a media link just times out, because the main loop
	// doesn't know about it.)
	if bound, bound_err := net.bound_endpoint(udp); bound_err == nil && !media {
		browser_left(bound.port)
	}
}

// Departed describes a browser that has gone. The server drops the sessions
// of such browsers immediately (see drop_departed_browsers) instead of
// waiting for them to time out. The web client can't send Leave when its
// tab closes, but the relay sees the WebSocket close. The port is the
// relay's own UDP port for that browser, which is how the server knows the
// browser. This is shared by the relay's threads and the server's loop.
@(private = "file")
Departed :: struct {
	port: int,
	at:   time.Tick,
}

@(private = "file")
departed_mutex: sync.Mutex
@(private = "file")
departed: [dynamic]Departed

@(private = "file")
browser_left :: proc(port: int) {
	sync.guard(&departed_mutex)
	append(&departed, Departed{port, time.tick_now()})
}

// drop_departed_browsers drops the sessions of browsers that have left the
// relay. Only sessions that haven't been heard from since the browser left
// are dropped, so if the port has already been taken by the next browser,
// its session is left alone.
drop_departed_browsers :: proc(s: ^Server) {
	gone: []Departed
	{
		sync.guard(&departed_mutex)
		if len(departed) == 0 {
			return
		}
		gone = slice.clone(departed[:], context.temp_allocator)
		clear(&departed)
	}
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for d in gone {
		for idx, c in s.sessions {
			heard := c.last_recv if c.keyed else c.started
			if c.endpoint == {net.IP4_Loopback, d.port} && time.tick_diff(heard, d.at) >= 0 {
				append(&stale, idx)
			}
		}
	}
	for idx in stale {
		drop_session(s, idx)
	}
}

// Link is shared by both directions of a relay. They use the same
// WebSocket, whose frames must not be interleaved, and a flag that tells
// both to stop.
@(private = "file")
Link :: struct {
	ws:          net.TCP_Socket,
	udp:         net.UDP_Socket,
	server:      net.Endpoint,
	write_mutex: sync.Mutex,
	done:        bool, // atomic
}

@(private = "file")
server_to_browser :: proc(link: ^Link) {
	// This thread needs its own temp allocator. The one it was started with
	// belongs to the other direction.
	temp: runtime.Arena
	context.temp_allocator = connection_temp_allocator(&temp)
	defer runtime.arena_destroy(&temp)
	buf: [http.MAX_FRAME]u8
	for !sync.atomic_load(&link.done) {
		n, from, err := net.recv_udp(link.udp, buf[:])
		if err != nil {
			#partial switch err {
			case .Timeout, .Would_Block:
				continue
			}
			break
		}
		// Only replies from the server are forwarded. Anything else is ignored.
		if from != link.server {
			continue
		}
		sync.guard(&link.write_mutex)
		if !http.write_frame(link.ws, .Binary, buf[:n]) {
			break
		}
	}
	sync.atomic_store(&link.done, true)
}

@(private = "file")
serve_file :: proc(r: ^Relay, sock: net.TCP_Socket, path: string) {
	name := strings.trim_prefix(path, "/")
	if name == "" {
		name = "index.html"
	}
	for f in r.files {
		if f.name != name {
			continue
		}
		if !f.loaded {
			http.respond(
				sock,
				"404 Not Found",
				"text/plain",
				"the web client has not been built\n",
			)
			return
		}
		http.respond(sock, "200 OK", f.content_type, string(f.data))
		return
	}
	http.respond(sock, "404 Not Found", "text/plain", "not found\n")
}
