package server

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "lib:http"

// Tests of how the relay answers browsers (relay.odin): which file a path is,
// what is refused, and relaying a WebSocket to the server's UDP port and back.
// The relay's connection handling runs over loopback sockets.

@(private = "file")
Peer :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket, // the browser's end
	conn:     ^http.Conn, // the relay's end (freed by the relay when it is done)
}

@(private = "file")
peer_open :: proc(t: ^testing.T) -> (p: Peer) {
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	p.listener = listener
	ep, _ := net.bound_endpoint(listener)
	client, dial_err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, ep.port})
	testing.expect(t, dial_err == nil)
	p.client = client
	accepted, from, accept_err := net.accept_tcp(listener)
	testing.expect(t, accept_err == nil)
	p.conn = new(http.Conn)
	p.conn.sock, p.conn.remote = accepted, from
	net.set_option(p.client, .Receive_Timeout, 3 * time.Second)
	return
}

@(private = "file")
peer_close :: proc(p: Peer) {
	net.close(p.client)
	net.close(p.listener)
}

// test_relay makes a relay that serves two files, one of which "could not be read".
@(private = "file")
test_relay :: proc(web := true) -> ^Relay {
	r := new(Relay)
	r.web = web
	r.files = {
		{name = "index.html", content_type = "text/html; charset=utf-8", data = transmute([]u8)string("<html>yap</html>"), loaded = true},
		{name = "index.js", content_type = "text/javascript; charset=utf-8"}, // not loaded
		{name = "index.wasm", content_type = "application/wasm", data = transmute([]u8)string("\x00asm"), loaded = true},
		{name = "sw.js", content_type = "text/javascript; charset=utf-8", data = transmute([]u8)string("//sw"), loaded = true},
		{},
		{},
		{},
		{},
		{},
	}
	return r
}

// get sends `request` to the relay and returns everything it answers.
@(private = "file")
exchange :: proc(t: ^testing.T, r: ^Relay, request: string) -> string {
	p := peer_open(t)
	defer peer_close(p)
	testing.expect(t, http.send_all(p.client, transmute([]u8)request))
	handle_connection(r, p.conn)
	data := make([dynamic]u8, context.temp_allocator)
	buf: [2048]u8
	for {
		n, err := net.recv_tcp(p.client, buf[:])
		if err != nil || n == 0 {
			break
		}
		append(&data, ..buf[:n])
	}
	return string(data[:])
}

@(private = "file")
status_of :: proc(response: string) -> string {
	line, _, _ := strings.partition(response, "\r\n")
	return line
}

@(private = "file")
body_of :: proc(response: string) -> string {
	_, _, body := strings.partition(response, "\r\n\r\n")
	return body
}

@(test)
test_relay_serves_its_files :: proc(t: ^testing.T) {
	r := test_relay()
	defer free(r)

	res := exchange(t, r, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 200 OK")
	testing.expect_value(t, body_of(res), "<html>yap</html>")
	testing.expect(t, strings.contains(res, "Content-Type: text/html; charset=utf-8\r\n"))
	testing.expect(t, strings.contains(res, "Content-Length: 16\r\n"))

	// By name, with the right type, and ignoring the page's query.
	res = exchange(t, r, "GET /index.html?server=chat.example.org HTTP/1.1\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 200 OK")
	testing.expect_value(t, body_of(res), "<html>yap</html>")
	res = exchange(t, r, "GET /index.wasm HTTP/1.1\r\n\r\n")
	testing.expect(t, strings.contains(res, "Content-Type: application/wasm\r\n"))
	testing.expect_value(t, body_of(res), "\x00asm")
	res = exchange(t, r, "GET /sw.js HTTP/1.1\r\n\r\n")
	testing.expect_value(t, body_of(res), "//sw")

	// A file that couldn't be read at startup says so.
	res = exchange(t, r, "GET /index.js HTTP/1.1\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 404 Not Found")
	testing.expect(t, strings.contains(res, "has not been built"))
}

@(test)
test_relay_serves_only_what_it_lists :: proc(t: ^testing.T) {
	r := test_relay()
	defer free(r)
	for path in ([]string {
			"/nothing",
			"/../config.json",
			"/..%2fconfig.json",
			"/%2e%2e/config.json",
			"/index.html/",
			"//index.html",
			"/INDEX.HTML",
			"/index.html%00.png",
			"/yap-server",
			"/web/out/index.html",
			"/./index.html",
			"/icon-192.png", // listed, but no file was found for it
		}) {
		res := exchange(t, r, strings.concatenate({"GET ", path, " HTTP/1.1\r\n\r\n"}, context.temp_allocator))
		testing.expectf(t, status_of(res) == "HTTP/1.1 404 Not Found", "%q: %s", path, status_of(res))
		testing.expectf(t, !strings.contains(res, "<html>"), "%q gave out a file", path)
	}
}

@(test)
test_relay_answers_only_get :: proc(t: ^testing.T) {
	r := test_relay()
	defer free(r)
	for method in ([]string{"POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"}) {
		res := exchange(t, r, strings.concatenate({method, " / HTTP/1.1\r\nContent-Length: 0\r\n\r\n"}, context.temp_allocator))
		testing.expectf(t, status_of(res) == "HTTP/1.1 405 Method Not Allowed", "%s: %s", method, status_of(res))
	}
}

@(test)
test_relay_without_the_web_client_or_the_api :: proc(t: ^testing.T) {
	// The API is not enabled here: its paths are not the web client's.
	r := test_relay()
	defer free(r)
	res := exchange(t, r, "GET /api/v1/server HTTP/1.1\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 404 Not Found")
	testing.expect(t, strings.contains(res, "API is not enabled"))

	// A relay that only serves the API doesn't serve files or relay browsers.
	api_only := test_relay(web = false)
	defer free(api_only)
	res = exchange(t, api_only, "GET / HTTP/1.1\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 404 Not Found")
	testing.expect(t, strings.contains(res, "only provides the API"))
	res = exchange(t, api_only, "GET /yap/x HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 404 Not Found")
	testing.expect(t, !strings.contains(res, "101"))
}

@(test)
test_relay_refuses_bad_requests :: proc(t: ^testing.T) {
	r := test_relay()
	defer free(r)

	// A request that can't be read gets no answer at all.
	for bad in ([]string{"\r\n\r\n", "GARBAGE\r\n\r\n", "GET\r\n\r\n"}) {
		res := exchange(t, r, bad)
		testing.expectf(t, res == "", "%q was answered: %q", bad, res)
	}
	// A WebSocket path without an upgrade, or without a key.
	res := exchange(t, r, "GET /yap/server HTTP/1.1\r\nHost: x\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 400 Bad Request")
	res = exchange(t, r, "GET /yap/server HTTP/1.1\r\nUpgrade: websocket\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 400 Bad Request")
	res = exchange(t, r, "GET /yap/server HTTP/1.1\r\nSec-WebSocket-Key: abc\r\n\r\n")
	testing.expect_value(t, status_of(res), "HTTP/1.1 400 Bad Request")

	// A page of another site doesn't get to use the relay.
	res = exchange(
		t,
		r,
		"GET /yap/server HTTP/1.1\r\nHost: relay.example.org\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\nOrigin: https://evil.example.com\r\n\r\n",
	)
	testing.expect_value(t, status_of(res), "HTTP/1.1 403 Forbidden")
	// ... unless the config lists it.
	// The media link is only there when the server has a media port.
	res = exchange(
		t,
		r,
		"GET /yap-media/server HTTP/1.1\r\nHost: relay.example.org\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\n\r\n",
	)
	testing.expect_value(t, status_of(res), "HTTP/1.1 404 Not Found")
	testing.expect(t, strings.contains(res, "media link is not enabled"))
}

// ---- relaying ----

@(private = "file")
Run :: struct {
	r: ^Relay,
	c: ^http.Conn,
}

@(test)
test_relay_carries_packets_both_ways :: proc(t: ^testing.T) {
	// The server, as a UDP socket of the test's.
	server, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, err == nil)
	defer net.close(server)
	server_ep, _ := net.bound_endpoint(server)
	net.set_option(server, .Receive_Timeout, 3 * time.Second)

	r := test_relay()
	defer free(r)
	r.server = {net.IP4_Loopback, server_ep.port}

	p := peer_open(t)
	defer peer_close(p)
	request := "GET /yap/server HTTP/1.1\r\nHost: relay.example.org\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	testing.expect(t, http.send_all(p.client, transmute([]u8)request))
	run := Run{r, p.conn}
	worker := thread.create_and_start_with_poly_data(
		&run,
		proc(run: ^Run) {handle_connection(run.r, run.c)},
		init_context = context,
	)
	defer thread.destroy(worker)

	// The upgrade is accepted, with the key's answer.
	head := make([dynamic]u8, context.temp_allocator)
	buf: [512]u8
	for !strings.contains(string(head[:]), "\r\n\r\n") {
		n, recv_err := net.recv_tcp(p.client, buf[:])
		if recv_err != nil || n == 0 {
			break
		}
		append(&head, ..buf[:n])
	}
	testing.expect_value(t, status_of(string(head[:])), "HTTP/1.1 101 Switching Protocols")
	testing.expect(t, strings.contains(string(head[:]), "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))

	// A browser's binary message arrives at the server as a datagram.
	browser := http.Conn {
		sock = p.client,
	}
	payload := []u8{1, 2, 3, 4, 5}
	testing.expect(t, http.write_frame(p.client, .Binary, payload, [4]u8{9, 8, 7, 6}))
	got: [2048]u8
	n, from, recv_err := net.recv_udp(server, got[:])
	testing.expect(t, recv_err == nil)
	testing.expect_value(t, string(got[:n]), "\x01\x02\x03\x04\x05")

	// What the server sends back to the relay's socket reaches the browser.
	_, send_err := net.send_udp(server, []u8{0xaa, 0xbb}, from)
	testing.expect(t, send_err == nil)
	frame: [http.MAX_FRAME]u8
	op, size, ok := http.read_frame(&browser, frame[:], from_server = true)
	testing.expect(t, ok)
	testing.expect_value(t, op, http.Opcode.Binary)
	testing.expect_value(t, string(frame[:size]), "\xaa\xbb")

	// A stranger's datagrams to the relay's socket are not passed on.
	stranger, s_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, s_err == nil)
	defer net.close(stranger)
	_, _ = net.send_udp(stranger, []u8{0xde, 0xad}, from)
	_, _ = net.send_udp(server, []u8{0x01}, from) // (the next real one)
	op, size, ok = http.read_frame(&browser, frame[:], from_server = true)
	testing.expect(t, ok)
	testing.expect_value(t, string(frame[:size]), "\x01")

	// Text is ignored, a ping is answered, and closing ends it.
	testing.expect(t, http.write_frame(p.client, .Text, []u8{'h', 'i'}, [4]u8{1, 2, 3, 4}))
	testing.expect(t, http.write_frame(p.client, .Ping, []u8{7}, [4]u8{1, 2, 3, 4}))
	op, size, ok = http.read_frame(&browser, frame[:], from_server = true)
	testing.expect(t, ok)
	testing.expect_value(t, op, http.Opcode.Pong)
	testing.expect_value(t, string(frame[:size]), "\x07")
	testing.expect(t, http.write_frame(p.client, .Close, nil, [4]u8{1, 2, 3, 4}))
	op, _, ok = http.read_frame(&browser, frame[:], from_server = true)
	testing.expect(t, ok)
	testing.expect_value(t, op, http.Opcode.Close)

	// Once the relay is done with the browser, the server is told it left.
	thread.join(worker)
	sync.guard(&departed_mutex)
	testing.expect_value(t, len(departed), 1)
	clear(&departed)
	delete(departed)
	departed = nil
}
