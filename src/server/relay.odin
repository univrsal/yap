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

/*
The relay, run alongside the server when the config enables it (see
config.odin): it lets the web client reach this server.

A browser can't send UDP, so the web client sends its packets over a
WebSocket instead, and the relay puts them back on UDP - one UDP socket
per WebSocket, so the server sees each browser as a client of its own.
It also serves the web build itself, so one address is all a browser
needs:

	"relay": { "enabled": true, "port": 8080 }   in config.json
	open http://localhost:8080/?server=localhost:7777

A browser's media link (client/conn/media.odin), for the video it
watches, comes the same way under /yap-media/ and goes to the server's
media port instead.

The relay can't read what it carries: the session is end-to-end between
the web client and the server, and the relay only ever sees sealed
packets. It only relays to this server, whatever address the page names,
so it can't be turned into a way to send UDP anywhere.

The bot API (common/gateway, docs/bot-api) is on the same port, under
/api/: one port, one proxy rule and one certificate for both. With the
API enabled and the relay not, the port serves the API and nothing else.
*/

DEFAULT_WEB_DIR :: "web/out"

// How long a UDP read waits before checking whether the WebSocket side
// has gone; also bounds how long a closed connection lingers.
@(private = "file")
UDP_POLL :: 200 * time.Millisecond

// A file a browser may ask for. They're read once, when the relay
// starts, so rebuilding the web client means restarting the server.
@(private = "file")
Web_File :: struct {
	name:         string,
	content_type: string,
	data:         []u8,
	loaded:       bool, // false if it couldn't be read
}

@(private = "file")
Relay :: struct {
	listener: net.TCP_Socket,
	server:   net.Endpoint, // the only places anything is relayed to
	media:    net.Endpoint, // the media port's; port 0 if there's none
	// Whether browsers are relayed and the web client served; without,
	// it's only the API.
	web:      bool,
	// Nothing else in the web directory is served.
	files:    [9]Web_File,
	api:      ^gateway.Gateway, // nil without the API
}

/*
start_relay listens for browsers on `port` and relays them to the server
on `server_port` of this machine (and their media links to `media_port`,
if it's not 0), on a thread of its own; with `web`
false it doesn't, and only answers the API. `api` is the gateway to hand
/api/ to, if there's one. It fails only if it can't listen; after that
it runs for as long as the process does.
*/
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
		// What installing it as an app needs (index.html).
		{name = "manifest.webmanifest", content_type = "application/manifest+json"},
		{name = "icon-192.png", content_type = "image/png"},
		{name = "icon-512.png", content_type = "image/png"},
		{name = "apple-touch-icon.png", content_type = "image/png"},
		// The service worker that shows pushes (push.odin, web/sw.js).
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
				"could not read %s: %v (built the web client? see web/build.sh)",
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

// A connection thread's temp allocations are a request's headers and a
// few strings, so it starts small rather than with the default 4 MiB.
@(private = "file")
CONNECTION_TEMP :: 16 * 1024

/*
Each connection thread brings its own temp allocator, freed as it ends:

	temp: runtime.Arena
	context.temp_allocator = connection_temp_allocator(&temp)
	defer runtime.arena_destroy(&temp)

The default one would be a 4 MiB block per thread, zeroed and so all
resident, which core:thread doesn't free for a thread started with an
init_context, and which malloc keeps around even once it's freed.
*/
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
	// The address may carry the page's query (?server=...), which
	// parse_request keeps apart from the path.
	req, parsed := http.parse_request(head)
	if !parsed {
		return
	}
	if strings.has_prefix(req.path, gateway.API_PREFIX) {
		if r.api == nil {
			http.respond(c.sock, "404 Not Found", "text/plain", "this server has no API\n")
			return
		}
		gateway.serve(r.api, c, req)
		return
	}
	if !r.web {
		http.respond(c.sock, "404 Not Found", "text/plain", "only the API is here\n")
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
			http.respond(c.sock, "404 Not Found", "text/plain", "the media link is off\n")
			return
		}
		target := req.path[len("/yap-media/" if media else "/yap/"):]
		relay_websocket(r, c, target, key, media)
		return
	}
	serve_file(r, c.sock, req.path)
}

/*
relay_websocket carries packets between one browser and the server
until either end goes: WebSocket messages out as UDP datagrams, UDP
datagrams back as WebSocket messages, one to one. `target` is the
address the page was given for the server; it's only for the log, as
the relay goes to its own server whatever the page asked for. A `media`
link goes to the server's media port.
*/
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
		// Nothing the client sends; ignored.
		case:
			break loop
		}
	}
	sync.atomic_store(&link.done, true)
	thread.join(back)
	thread.destroy(back)
	log.infof("a browser%s left (which asked for %s)", "'s media link" if media else "", target)
	// Before the socket closes: what the server sends it from now on
	// would only come back as ICMP "port unreachable". (A media link's
	// session just times out: the main loop doesn't know it.)
	if bound, bound_err := net.bound_endpoint(udp); bound_err == nil && !media {
		browser_left(bound.port)
	}
}

/*
Browsers that have gone, for the server to drop their sessions at once
(drop_departed_browsers) rather than when they time out: the web client
can't send Leave as the tab closes, but the relay sees its WebSocket go.
It's the relay's own UDP port that's left, which the server knows the
browser by. Shared by the relay's threads and the server's loop.
*/
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

/*
drop_departed_browsers drops the sessions of browsers that have left the
relay. Only those not heard from since: should the port be taken by the
next browser already, its session is left be.
*/
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

// The two directions share the WebSocket, whose frames mustn't
// interleave, and a flag to stop on.
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
	// Not the one it was started with, which is the other direction's.
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
		// Only the server's replies go back; anything else is noise.
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
			http.respond(sock, "404 Not Found", "text/plain", "the web client hasn't been built\n")
			return
		}
		http.respond(sock, "200 OK", f.content_type, string(f.data))
		return
	}
	http.respond(sock, "404 Not Found", "text/plain", "not found\n")
}
