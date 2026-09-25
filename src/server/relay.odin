package server

import "core:log"
import "core:net"
import "core:os"
import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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

The relay can't read what it carries: the session is end-to-end between
the web client and the server, and the relay only ever sees sealed
packets. It only relays to this server, whatever address the page names,
so it can't be turned into a way to send UDP anywhere.
*/

DEFAULT_WEB_DIR :: "web/out"

// How long a UDP read waits before checking whether the WebSocket side
// has gone; also bounds how long a closed connection lingers.
@(private = "file")
UDP_POLL :: 200 * time.Millisecond

// A browser's request line and headers fit comfortably in this; one
// that doesn't isn't a browser asking for yap.
@(private = "file")
MAX_REQUEST :: 8192

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
	server:   net.Endpoint, // the only place anything is relayed to
	// Nothing else in the web directory is served.
	files:    [3]Web_File,
}

/*
start_relay listens for browsers on `port` and relays them to the server
on `server_port` of this machine, on a thread of its own. It fails only
if it can't listen; after that it runs for as long as the process does.
*/
start_relay :: proc(port: int, server_port: int, web_dir: string) -> bool {
	listener, err := net.listen_tcp({net.IP4_Any, port})
	if err != nil {
		log.errorf("could not listen on port %d: %v", port, err)
		return false
	}

	r := new(Relay)
	r.listener = listener
	r.server = {net.IP4_Loopback, server_port}
	r.files = {
		{name = "index.html", content_type = "text/html; charset=utf-8"},
		{name = "index.js", content_type = "text/javascript; charset=utf-8"},
		{name = "index.wasm", content_type = "application/wasm"},
	}
	for &f in r.files {
		full, _ := filepath.join({web_dir, f.name}, context.temp_allocator)
		data, read_err := os.read_entire_file(full, context.allocator)
		if read_err != nil {
			log.errorf("could not read %s: %v (built the web client? see web/build.sh)", full, read_err)
			continue
		}
		f.data, f.loaded = data, true
	}
	log.infof("relaying browsers to udp :%d; serving %s on http://localhost:%d/", server_port, web_dir, port)
	thread.create_and_start_with_poly_data(r, accept_browsers, init_context = context, self_cleanup = true)
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
		c := new(Conn)
		c.sock = sock
		log.debugf("connection from %s", net.endpoint_to_string(from, context.temp_allocator))
		thread.create_and_start_with_poly_data2(r, c, handle_connection, init_context = context, self_cleanup = true)
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
handle_connection :: proc(r: ^Relay, c: ^Conn) {
	temp: runtime.Arena
	context.temp_allocator = connection_temp_allocator(&temp)
	defer runtime.arena_destroy(&temp)
	defer free(c)
	defer net.close(c.sock)

	head, ok := read_request(c)
	if !ok {
		return
	}
	method, path, upgrade, key := parse_request(head)
	if method != "GET" {
		respond(c.sock, "405 Method Not Allowed", "text/plain", "the yap relay only answers GET\n")
		return
	}
	// The address may carry the page's query (?server=...); only the
	// path matters here.
	if i := strings.index_byte(path, '?'); i >= 0 {
		path = path[:i]
	}

	if strings.has_prefix(path, "/yap/") {
		if !strings.equal_fold(upgrade, "websocket") || key == "" {
			respond(c.sock, "400 Bad Request", "text/plain", "expected a WebSocket upgrade\n")
			return
		}
		relay_websocket(r, c, path[len("/yap/"):], key)
		return
	}
	serve_file(r, c.sock, path)
}

/*
relay_websocket carries packets between one browser and the server
until either end goes: WebSocket messages out as UDP datagrams, UDP
datagrams back as WebSocket messages, one to one. `target` is the
address the page was given for the server; it's only for the log, as
the relay goes to its own server whatever the page asked for.
*/
@(private = "file")
relay_websocket :: proc(r: ^Relay, c: ^Conn, target: string, key: string) {
	udp, udp_err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if udp_err != nil {
		log.errorf("could not open a UDP socket: %v", udp_err)
		respond(c.sock, "502 Bad Gateway", "text/plain", "could not open a UDP socket\n")
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
			accept_key(key),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !send_all(c.sock, transmute([]u8)accept) {
		return
	}
	log.infof("relaying a browser (which asked for %s)", target)

	link := Link {
		ws     = c.sock,
		udp    = udp,
		server = r.server,
	}
	back := thread.create_and_start_with_poly_data(&link, server_to_browser, init_context = context)

	payload: [MAX_FRAME]u8
	loop: for !sync.atomic_load(&link.done) {
		op, n, ok := read_frame(c, payload[:])
		if !ok {
			break
		}
		#partial switch op {
		case .Binary:
			net.send_udp(udp, payload[:n], r.server)
		case .Ping:
			sync.guard(&link.write_mutex)
			write_frame(c.sock, .Pong, payload[:n])
		case .Close:
			sync.guard(&link.write_mutex)
			write_frame(c.sock, .Close, nil)
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
	log.infof("a browser left (which asked for %s)", target)
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
	buf: [MAX_FRAME]u8
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
		if !write_frame(link.ws, .Binary, buf[:n]) {
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
			respond(sock, "404 Not Found", "text/plain", "the web client hasn't been built\n")
			return
		}
		respond(sock, "200 OK", f.content_type, string(f.data))
		return
	}
	respond(sock, "404 Not Found", "text/plain", "not found\n")
}

@(private = "file")
respond :: proc(sock: net.TCP_Socket, status, content_type, body: string) {
	head := strings.concatenate(
		{
			"HTTP/1.1 ",
			status,
			"\r\nContent-Type: ",
			content_type,
			"\r\nContent-Length: ",
			itoa(len(body)),
			"\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
		},
		context.temp_allocator,
	)
	send_all(sock, transmute([]u8)head)
	send_all(sock, transmute([]u8)body)
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf: [20]u8
	i := len(buf)
	n := n
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

// read_request reads up to the end of the request's headers. Whatever
// came in after them stays in the buffer for the frames that follow.
@(private = "file")
read_request :: proc(c: ^Conn) -> (head: string, ok: bool) {
	for {
		if i := strings.index(string(c.buf[:c.end]), "\r\n\r\n"); i >= 0 {
			c.start = i + 4
			return strings.clone(string(c.buf[:i]), context.temp_allocator), true
		}
		if c.end >= min(len(c.buf), MAX_REQUEST) {
			return "", false
		}
		n, err := net.recv_tcp(c.sock, c.buf[c.end:])
		if err != nil || n == 0 {
			return "", false
		}
		c.end += n
	}
}

@(private = "file")
parse_request :: proc(head: string) -> (method, path, upgrade, key: string) {
	lines := strings.split_lines(head, context.temp_allocator)
	if len(lines) == 0 {
		return
	}
	parts := strings.fields(lines[0], context.temp_allocator)
	if len(parts) >= 2 {
		method, path = parts[0], parts[1]
	}
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		switch {
		case strings.equal_fold(name, "Upgrade"):
			upgrade = value
		case strings.equal_fold(name, "Sec-WebSocket-Key"):
			key = value
		}
	}
	return
}
