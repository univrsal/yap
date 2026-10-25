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

import "common:proto"
import "gate"
import "lib:gateway"
import "lib:http"

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
// The bot API (see lib/gateway and docs/bot-api) is served on the same
// port under /api/, so that one port, one proxy rule and one certificate
// are enough for both. If the API is enabled but the relay is not, the port
// serves the API and nothing else.

DEFAULT_WEB_DIR :: "web/out"

// How long a UDP read waits before checking whether the WebSocket side
// has gone. This also limits how long a closed connection lingers.
@(private = "file")
UDP_POLL :: 200 * time.Millisecond

// At most this many browsers and API clients are connected at once. Each
// is a thread (a relayed browser two, and a UDP socket), so more are closed
// right away rather than let a flood of connections use up the threads and
// sockets of the process that is also the chat server.
@(private = "file")
MAX_CONNECTIONS :: 256

// At most this many of them from one address, so that one address can't
// take them all. Behind a reverse proxy, all of them come from the proxy, so
// this machine and private networks aren't limited (gateway.address_private).
@(private = "file")
MAX_CONNECTIONS_PER_ADDRESS :: 32

// How long a connection may take to send a request's head, so that
// connections that send nothing (or a byte at a time) don't stay forever.
@(private = "file")
HEAD_TIMEOUT :: 10 * time.Second

// How long a relayed browser may send nothing before it's disconnected. The
// client sends a keepalive every proto.KEEPALIVE_AFTER, but a browser may
// slow down the timers of a tab in the background a lot.
@(private = "file")
WEBSOCKET_IDLE :: 5 * time.Minute

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
	listener:      net.TCP_Socket,
	server:        net.Endpoint, // the only destination that packets are relayed to
	media:         net.Endpoint, // the server's media port, or port 0 if there is none
	// Whether browsers are relayed and the web client is served. If false,
	// only the API is served.
	web:           bool,
	// The other sites whose pages may connect (Relay_Config.allow_sites).
	allow_sites:   []string,
	// Only these files of the web directory are served.
	files:         [9]Web_File,
	api:           ^gateway.Gateway, // nil if the API is disabled
	// How many connections there are, in total and by address, which the
	// threads count down when they end (see MAX_CONNECTIONS).
	open:          int,
	by_addr_mutex: sync.Mutex,
	by_addr:       map[gate.Key]int,
}

// start_relay listens for browsers on `port` (of `bind`) in a thread of its own and
// relays them to the server on `server_port` of this machine. Media links
// are relayed to `media_port` unless it is 0. If `web` is false, browsers
// aren't relayed and only the API is served. `api` is the gateway that
// requests under /api/ are handed to, if there is one. It only fails if it
// can't listen. After that it runs for as long as the process does.
start_relay :: proc(
	port: int,
	bind: string, // "" for all interfaces
	server_port: int,
	media_port: int,
	web_dir: string,
	web := true,
	api: ^gateway.Gateway = nil,
	allow_sites: []string = nil, // normalized origins, or "*" (see relay_site_allowed)
) -> bool {
	address: net.Address = net.IP4_Any
	if bind != "" {
		address = net.parse_address(bind)
	}
	listener, err := net.listen_tcp({address, port})
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
	r.allow_sites = allow_sites
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
		if !relay_count(r, from) {
			log.warnf(
				"too many connections, closing the one from %s",
				net.endpoint_to_string(from, context.temp_allocator),
			)
			net.close(sock)
			continue
		}
		c := new(http.Conn)
		c.sock, c.remote = sock, from
		log.debugf("connection from %s", net.endpoint_to_string(from, context.temp_allocator))
		started := thread.create_and_start_with_poly_data2(
			r,
			c,
			handle_connection,
			init_context = context,
			self_cleanup = true,
		)
		if started == nil {
			log.warn("could not start a thread for a connection")
			net.close(sock)
			free(c)
			relay_uncount(r, from)
		}
	}
}

// relay_count counts a new connection from `from`, unless there are too many
// (MAX_CONNECTIONS, MAX_CONNECTIONS_PER_ADDRESS).
@(private = "file")
relay_count :: proc(r: ^Relay, from: net.Endpoint) -> bool {
	sync.guard(&r.by_addr_mutex)
	if r.open >= MAX_CONNECTIONS {
		return false
	}
	addr := gate.key_of(from)
	if !gateway.address_private(from.address) {
		if r.by_addr[addr] >= MAX_CONNECTIONS_PER_ADDRESS {
			return false
		}
		r.by_addr[addr] += 1
	}
	r.open += 1
	return true
}

@(private = "file")
relay_uncount :: proc(r: ^Relay, from: net.Endpoint) {
	sync.guard(&r.by_addr_mutex)
	r.open -= 1
	if gateway.address_private(from.address) {
		return
	}
	addr := gate.key_of(from)
	if n := r.by_addr[addr]; n > 1 {
		r.by_addr[addr] = n - 1
	} else {
		delete_key(&r.by_addr, addr)
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
	remote := c.remote // c is freed before this defer runs
	defer relay_uncount(r, remote)
	defer free(c)
	defer net.close(c.sock)

	// gateway.serve sets timeouts of its own for the API.
	net.set_option(c.sock, .Receive_Timeout, HEAD_TIMEOUT)
	net.set_option(c.sock, .Send_Timeout, HEAD_TIMEOUT)
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
			http.respond(c.sock, 404, "text/plain", "the API is not enabled on this server\n")
			return
		}
		gateway.serve(r.api, c, req)
		return
	}
	if !r.web {
		http.respond(
			c.sock,
			404,
			"text/plain",
			"this server only provides the API, not the web client\n",
		)
		return
	}
	if req.method != "GET" {
		http.respond(c.sock, 405, "text/plain", "the yap relay only answers GET\n")
		return
	}
	media := strings.has_prefix(req.path, "/yap-media/")
	if media || strings.has_prefix(req.path, "/yap/") {
		key := http.header(&req, "Sec-WebSocket-Key")
		if !strings.equal_fold(http.header(&req, "Upgrade"), "websocket") || key == "" {
			http.respond(c.sock, 400, "text/plain", "expected a WebSocket upgrade\n")
			return
		}
		page := Relay_Request {
			origin         = http.header(&req, "Origin"),
			fetch_site     = http.header(&req, "Sec-Fetch-Site"),
			host           = http.header(&req, "Host"),
			forwarded_host = http.header(&req, "X-Forwarded-Host"),
		}
		if !relay_site_allowed(r.allow_sites, page) {
			log.infof(
				"refused a browser on a page of %s, which isn't this relay's site (%s) nor in its allow_sites",
				page.origin,
				page.forwarded_host if page.forwarded_host != "" else page.host,
			)
			http.respond(
				c.sock,
				403,
				"text/plain",
				"this server's relay doesn't accept web clients of other sites\n",
			)
			return
		}
		if media && r.media.port == 0 {
			http.respond(
				c.sock,
				404,
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

// Relay_Request is what a WebSocket request says about the page that made
// it (see relay_site_allowed): its headers, as received.
Relay_Request :: struct {
	origin:         string, // Origin
	fetch_site:     string, // Sec-Fetch-Site
	host:           string, // Host
	forwarded_host: string, // X-Forwarded-Host, from a reverse proxy
}

// relay_site_allowed is whether a page may connect through the relay. Only the
// web client of this relay's own site may, and those of the sites the config
// allows (Relay_Config.allow_sites), not a page of another site that a visitor
// happens to have open, which could otherwise use their browser to reach a
// relay inside their network.
//
// A browser always says which page it is in Origin, which the page can't
// change. A request without one isn't from a browser, so it can't be a page
// using its visitor's browser, and anyone who can send it could just as well
// send UDP to the server. Some browsers also say in Sec-Fetch-Site whether the
// page is of the same site, which counts other subdomains of the same domain
// too. Chrome doesn't send that with a WebSocket, so then the page's host has
// to be the one the request was sent to: Host, or what a reverse proxy says
// it was in X-Forwarded-Host if it replaced Host with its own. Ports don't
// matter, as for sites.
relay_site_allowed :: proc(allow_sites: []string, req: Relay_Request) -> bool {
	if req.origin == "" {
		return true
	}
	page := strings.trim_suffix(strings.trim_space(req.origin), "/")
	if !is_origin(page) {
		return false // "null", from a sandboxed frame or a file
	}
	for site in allow_sites {
		if site == "*" || strings.equal_fold(site, page) {
			return true
		}
	}
	switch {
	case strings.equal_fold(req.fetch_site, "same-origin"),
	     strings.equal_fold(req.fetch_site, "same-site"):
		return true
	case req.fetch_site != "":
		return false
	}
	page_host := host_of(page[strings.index(page, "://") + 3:])
	forwarded, _, _ := strings.partition(req.forwarded_host, ",")
	return(
		strings.equal_fold(page_host, host_of(req.host)) ||
		strings.equal_fold(page_host, host_of(forwarded)) \
	)
}

// host_of returns the host of "host", "host:port", "[v6]" or "[v6]:port", or
// "" if there is none.
@(private = "file")
host_of :: proc(host: string) -> string {
	s := strings.trim_space(host)
	if strings.has_prefix(s, "[") {
		end := strings.index_byte(s, ']')
		return s[:end + 1] if end > 0 else ""
	}
	if colon := strings.last_index_byte(s, ':'); colon >= 0 {
		return s[:colon]
	}
	return s
}

// is_origin is whether `s` is an origin: http:// or https://, then a host and
// maybe a port, and nothing else.
@(private = "file")
is_origin :: proc(s: string) -> bool {
	rest: string
	switch {
	case len(s) > len("https://") && strings.equal_fold(s[:len("https://")], "https://"):
		rest = s[len("https://"):]
	case len(s) > len("http://") && strings.equal_fold(s[:len("http://")], "http://"):
		rest = s[len("http://"):]
	case:
		return false
	}
	return rest != "" && !strings.contains_any(rest, "/?#@ \\")
}

// site_origin normalizes an entry of allow_sites: "*" as it is, or an origin
// (see is_origin, a trailing slash allowed) in lower case without the slash.
// The result is allocated, since it is kept with the config.
site_origin :: proc(site: string) -> (origin: string, ok: bool) {
	s := strings.trim_suffix(strings.trim_space(site), "/")
	if s == "*" {
		return strings.clone(s), true
	}
	if !is_origin(s) {
		return "", false
	}
	return strings.to_lower(s), true
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
		http.respond(c.sock, 502, "text/plain", "could not open a UDP socket\n")
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
	net.set_option(c.sock, .Receive_Timeout, WEBSOCKET_IDLE)
	log.infof(
		"relaying a browser%s (which asked for %s)",
		"'s media link" if media else "",
		http.printable(target),
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
	log.infof(
		"a browser%s left (which asked for %s)",
		"'s media link" if media else "",
		http.printable(target),
	)
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
			http.respond(sock, 404, "text/plain", "the web client has not been built\n")
			return
		}
		http.respond(sock, 200, f.content_type, string(f.data))
		return
	}
	http.respond(sock, 404, "text/plain", "not found\n")
}
