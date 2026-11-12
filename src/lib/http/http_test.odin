package http

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"


// Tests of the HTTP and WebSocket code the relay and the bot API are built on:
// parsing what a peer sends (which cannot be trusted), and what is sent back.

// ---- parsing a request ----

@(test)
test_parse_request :: proc(t: ^testing.T) {
	req, ok := parse_request(
		"POST /api/channels/3/messages?limit=10&before=7 HTTP/1.1\r\nHost: example.org\r\nContent-Length: 12\r\nAuthorization: Bearer abc",
	)
	testing.expect(t, ok)
	testing.expect_value(t, req.method, "POST")
	testing.expect_value(t, req.path, "/api/channels/3/messages")
	testing.expect_value(t, req.query, "limit=10&before=7")
	testing.expect_value(t, req.content_length, 12)
	testing.expect(t, req.keep_alive, "HTTP/1.1 keeps the connection by default")
	testing.expect(t, !req.chunked)
	testing.expect_value(t, len(req.headers), 3)
	// Names are matched without regard to case, values are trimmed.
	testing.expect_value(t, header(&req, "authorization"), "Bearer abc")
	testing.expect_value(t, header(&req, "HOST"), "example.org")
	testing.expect_value(t, header(&req, "X-Missing"), "")

	// No query, no body size.
	req, ok = parse_request("GET / HTTP/1.1")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, "/")
	testing.expect_value(t, req.query, "")
	testing.expect_value(t, req.content_length, -1)

	// An empty query is still a query.
	req, _ = parse_request("GET /x? HTTP/1.1")
	testing.expect_value(t, req.path, "/x")
	testing.expect_value(t, req.query, "")
	// Only the first ? ends the path.
	req, _ = parse_request("GET /x?a=b?c HTTP/1.1")
	testing.expect_value(t, req.query, "a=b?c")
}

@(test)
test_parse_request_line :: proc(t: ^testing.T) {
	for bad in ([]string{"", "GET", "   ", "\r\nGET / HTTP/1.1"}) {
		_, ok := parse_request(bad)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}
	// A request without a version is HTTP/1.0, which closes by default.
	req, ok := parse_request("GET /")
	testing.expect(t, ok)
	testing.expect(t, !req.keep_alive)
	req, _ = parse_request("GET / HTTP/1.0")
	testing.expect(t, !req.keep_alive)
	// Extra spaces and tabs between the parts are fine.
	req, ok = parse_request("GET\t/a \t HTTP/1.1")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, "/a")
}

@(test)
test_parse_request_connection :: proc(t: ^testing.T) {
	Case :: struct {
		head:       string,
		keep_alive: bool,
	}
	cases := []Case {
		{"GET / HTTP/1.1\r\nConnection: close", false},
		{"GET / HTTP/1.1\r\nConnection: Close", false},
		{"GET / HTTP/1.1\r\nConnection: keep-alive", true},
		{"GET / HTTP/1.0\r\nConnection: keep-alive", true},
		{"GET / HTTP/1.0\r\nConnection: Keep-Alive, Upgrade", true},
		{"GET / HTTP/1.1\r\nConnection: Upgrade, close", false},
		{"GET / HTTP/1.1\r\nConnection: upgrade", true},
		{"GET / HTTP/1.1\r\nConnection: closed", true}, // a token, not a prefix
	}
	for c in cases {
		req, ok := parse_request(c.head)
		testing.expect(t, ok)
		testing.expectf(t, req.keep_alive == c.keep_alive, "%q", c.head)
	}
}

@(test)
test_parse_request_content_length :: proc(t: ^testing.T) {
	good := []struct {
		value: string,
		size:  int,
	}{{"0", 0}, {"7", 7}, {"007", 7}, {"1048576", 1048576}, {"999999999999999", 999999999999999}}
	for g in good {
		req, ok := parse_request(
			strings.concatenate(
				{"POST / HTTP/1.1\r\nContent-Length: ", g.value},
				context.temp_allocator,
			),
		)
		testing.expectf(t, ok, "%q was refused", g.value)
		testing.expect_value(t, req.content_length, g.size)
	}

	// A size that is not plainly a number makes the request ambiguous, which is
	// how request smuggling starts.
	for bad in ([]string {
			"",
			"-1",
			"+5",
			"1_0",
			"0x10",
			"1.5",
			"5 5",
			"five",
			"9999999999999999", // too long to be sure it can't wrap
			"99999999999999999999999999",
		}) {
		_, ok := parse_request(
			strings.concatenate(
				{"POST / HTTP/1.1\r\nContent-Length: ", bad},
				context.temp_allocator,
			),
		)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}

	// Two lengths that agree are fine; two that differ are not.
	req, ok := parse_request("POST / HTTP/1.1\r\nContent-Length: 5\r\ncontent-length: 5")
	testing.expect(t, ok)
	testing.expect_value(t, req.content_length, 5)
	_, ok = parse_request("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6")
	testing.expect(t, !ok)
}

@(test)
test_parse_request_chunked :: proc(t: ^testing.T) {
	req, ok := parse_request("POST / HTTP/1.1\r\nTransfer-Encoding: chunked")
	testing.expect(t, ok)
	testing.expect(t, req.chunked)
	req, _ = parse_request("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked")
	testing.expect(t, req.chunked)
	req, _ = parse_request("POST / HTTP/1.1\r\nTransfer-Encoding: identity")
	testing.expect(t, !req.chunked)
	req, _ = parse_request("POST / HTTP/1.1\r\nHost: x")
	testing.expect(t, !req.chunked)
}

@(test)
test_parse_request_headers :: proc(t: ^testing.T) {
	req, ok := parse_request(
		"GET / HTTP/1.1\r\nno colon here\r\nX-A:1\r\n  X-B  :  two words  \r\nX-C: a:b:c\r\nX-A: again",
	)
	testing.expect(t, ok)
	// A line without a colon is skipped, the rest are kept in order.
	testing.expect_value(t, len(req.headers), 4)
	testing.expect_value(t, header(&req, "X-A"), "1") // the first of two
	testing.expect_value(t, header(&req, "X-B"), "two words")
	testing.expect_value(t, header(&req, "X-C"), "a:b:c")
}

@(test)
test_has_token :: proc(t: ^testing.T) {
	testing.expect(t, has_token("close", "close"))
	testing.expect(t, has_token("Upgrade, CLOSE", "close"))
	testing.expect(t, has_token(" a ,b,  close  ", "close"))
	testing.expect(t, !has_token("", "close"))
	testing.expect(t, !has_token("closed", "close"))
	testing.expect(t, !has_token("not-close", "close"))
	testing.expect(t, !has_token("a b", "a"))
}

// ---- percent-encoding and queries ----

@(test)
test_percent_decode :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, s: string, plus: bool, want: string, loc := #caller_location) {
		got, ok := percent_decode(s, plus)
		testing.expectf(t, ok, "%q was refused", s, loc = loc)
		testing.expect_value(t, got, want, loc)
	}
	check(t, "", false, "")
	check(t, "plain", false, "plain")
	check(t, "a%20b", false, "a b")
	check(t, "%41%42%43", false, "ABC")
	check(t, "%e2%82%ac", false, "€")
	check(t, "%E2%82%AC", false, "€")
	check(t, "a+b", false, "a+b")
	check(t, "a+b", true, "a b")
	check(t, "a%2Bb", true, "a+b") // an escaped plus stays a plus
	check(t, "100%25", false, "100%")
	check(t, "%00", false, "\x00")
	check(t, "%2f%2F", false, "//")

	for bad in ([]string{"%", "%4", "%zz", "%4g", "abc%", "abc%1", "%%41", "% 41"}) {
		_, ok := percent_decode(bad)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}
}

@(test)
test_query_value :: proc(t: ^testing.T) {
	v, found := query_value("a=1&b=two&c=", "b")
	testing.expect(t, found)
	testing.expect_value(t, v, "two")
	v, found = query_value("a=1&b=two&c=", "c")
	testing.expect(t, found)
	testing.expect_value(t, v, "")
	v, found = query_value("a=1&b=two", "a")
	testing.expect(t, found)
	testing.expect_value(t, v, "1")

	// The first of a name that is repeated.
	v, _ = query_value("a=1&a=2", "a")
	testing.expect_value(t, v, "1")
	// A name with no value.
	v, found = query_value("flag&a=1", "flag")
	testing.expect(t, found)
	testing.expect_value(t, v, "")

	// Decoded: plus is a space, and names are decoded before they are compared.
	v, _ = query_value("q=hello+world%21", "q")
	testing.expect_value(t, v, "hello world!")
	v, found = query_value("na%6De=x", "name")
	testing.expect(t, found)
	testing.expect_value(t, v, "x")

	// Not there, or not decodable.
	for name in ([]string{"z", "A", ""}) {
		_, found = query_value("a=1&b=2", name)
		testing.expectf(t, !found, "%q found", name)
	}
	_, found = query_value("a=%zz", "a")
	testing.expect(t, !found)
	_, found = query_value("", "a")
	testing.expect(t, !found)
	// A name that can't be decoded is skipped instead of ending the search.
	v, found = query_value("%zz=1&a=2", "a")
	testing.expect(t, found)
	testing.expect_value(t, v, "2")
	// A value containing = keeps it.
	v, _ = query_value("a=b=c", "a")
	testing.expect_value(t, v, "b=c")
}

@(test)
test_printable :: proc(t: ^testing.T) {
	testing.expect_value(t, printable("/plain/path?x=1"), "/plain/path?x=1")
	testing.expect_value(t, printable(""), "")
	// Control characters, escapes and non-ASCII can't reach a terminal.
	testing.expect_value(t, printable("a\x1b[31mred"), "a\\x1b[31mred")
	testing.expect_value(t, printable("line\r\nbreak"), "line\\x0d\\x0abreak")
	testing.expect_value(t, printable("é"), "\\xc3\\xa9")
	testing.expect_value(t, printable("del\x7f"), "del\\x7f")
	// A backslash is written as an escape too, so that an escape in the log is the real thing.
	testing.expect_value(t, printable(`a\x41`), "a\\x5cx41")

	long := strings.repeat("a", MAX_PRINTABLE + 50, context.temp_allocator)
	cut := printable(long)
	testing.expect_value(t, len(cut), MAX_PRINTABLE + 3)
	testing.expect(t, strings.has_suffix(cut, "..."))
	exact := strings.repeat("b", MAX_PRINTABLE, context.temp_allocator)
	testing.expect_value(t, printable(exact), exact)
}

@(test)
test_status_line :: proc(t: ^testing.T) {
	testing.expect_value(t, status_line(200), "200 OK")
	testing.expect_value(t, status_line(404), "404 Not Found")
	testing.expect_value(t, status_line(429), "429 Too Many Requests")
	// What it doesn't know reads as a server error, with the code it was given.
	testing.expect_value(t, status_line(418), "418 Internal Server Error")
	for code in ([]int{200, 201, 204, 400, 401, 403, 404, 405, 409, 410, 411, 413, 429, 501, 502, 503}) {
		line := status_line(code)
		testing.expectf(t, !strings.contains(line, "Internal"), "%d has no reason", code)
	}
}

// ---- the WebSocket handshake ----

@(test)
test_accept_key :: proc(t: ^testing.T) {
	// The example of RFC 6455, section 1.3.
	testing.expect_value(t, accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
	// It depends on the whole key.
	testing.expect(
		t,
		accept_key("dGhlIHNhbXBsZSBub25jZQ=") != accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
	)
	testing.expect_value(t, len(accept_key("")), 28)
}

// ---- connection limits ----

@(test)
test_conn_limit :: proc(t: ^testing.T) {
	l := Conn_Limit {
		max         = 4,
		per_address = 2,
	}
	defer delete(l.by_addr)
	a := net.Endpoint{net.IP4_Address{10, 0, 0, 1}, 1000}
	a2 := net.Endpoint{net.IP4_Address{10, 0, 0, 1}, 2000} // the same address, another port
	b := net.Endpoint{net.IP4_Address{10, 0, 0, 2}, 1000}

	// Two per address, whatever the ports.
	testing.expect(t, conn_count(&l, a))
	testing.expect(t, conn_count(&l, a2))
	testing.expect(t, !conn_count(&l, a), "a third connection from one address was taken")
	testing.expect_value(t, l.open, 2)
	testing.expect(t, conn_count(&l, b))

	// Closing one makes room for the same address, and only that.
	conn_uncount(&l, a)
	testing.expect_value(t, l.open, 2)
	testing.expect(t, conn_count(&l, a))
	testing.expect(t, !conn_count(&l, a2))

	// The total is limited too.
	c := net.Endpoint{net.IP4_Address{10, 0, 0, 3}, 1}
	testing.expect(t, conn_count(&l, c))
	testing.expect_value(t, l.open, 4)
	d := net.Endpoint{net.IP4_Address{10, 0, 0, 4}, 1}
	testing.expect(t, !conn_count(&l, d), "the total limit was passed")
	testing.expect_value(t, l.open, 4)

	// A refused connection leaves nothing to uncount: everything balances out.
	for e in ([]net.Endpoint{a, a, b, c}) {
		conn_uncount(&l, e)
	}
	testing.expect_value(t, l.open, 0)
	testing.expect_value(t, len(l.by_addr), 0)
}

@(private = "file")
is_proxy :: proc(address: net.Address) -> bool {
	return address == net.Address(net.IP4_Address{10, 9, 9, 9})
}

@(test)
test_conn_limit_exempt :: proc(t: ^testing.T) {
	l := Conn_Limit {
		max         = 5,
		per_address = 1,
		exempt      = is_proxy,
	}
	defer delete(l.by_addr)
	proxy := net.Endpoint{net.IP4_Address{10, 9, 9, 9}, 1}
	other := net.Endpoint{net.IP4_Address{10, 0, 0, 1}, 1}

	// A proxy's connections count towards the total only.
	for _ in 0 ..< 3 {
		testing.expect(t, conn_count(&l, proxy))
	}
	testing.expect_value(t, len(l.by_addr), 0)
	testing.expect(t, conn_count(&l, other))
	testing.expect(t, !conn_count(&l, other))
	testing.expect(t, conn_count(&l, proxy))
	testing.expect(t, !conn_count(&l, proxy), "the total limit was passed")

	for e in ([]net.Endpoint{proxy, proxy, proxy, proxy, other}) {
		conn_uncount(&l, e)
	}
	testing.expect_value(t, l.open, 0)
	testing.expect_value(t, len(l.by_addr), 0)
}

// ---- over a socket ----

// Pair is a connection through the loopback interface: `server` is the end
// that the code under test reads, `client` the end that the test writes.
@(private = "file")
Pair :: struct {
	client:   net.TCP_Socket,
	server:   Conn,
	listener: net.TCP_Socket,
}

@(private = "file")
pair_open :: proc(t: ^testing.T) -> (p: ^Pair) {
	p = new(Pair, context.temp_allocator)
	err: net.Network_Error
	p.listener, err = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	port: int
	if ep, ep_err := net.bound_endpoint(p.listener); ep_err == nil {
		port = ep.port
	}
	p.client, err = net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	testing.expect(t, err == nil)
	accepted, from, accept_err := net.accept_tcp(p.listener)
	testing.expect(t, accept_err == nil)
	p.server.sock, p.server.remote = accepted, from
	// A test that goes wrong fails instead of hanging.
	net.set_option(p.server.sock, .Receive_Timeout, 2 * time.Second)
	net.set_option(p.client, .Receive_Timeout, 2 * time.Second)
	return
}

// NO_SOCKET marks an end that was closed by the test. It is never closed a
// second time, because the number may belong to another test's socket by then.
@(private = "file")
NO_SOCKET :: net.TCP_Socket(-1)

@(private = "file")
pair_close :: proc(p: ^Pair) {
	for sock in ([]net.TCP_Socket{p.client, p.server.sock, p.listener}) {
		if sock != NO_SOCKET {
			net.close(sock)
		}
	}
}

// hang_up closes the client's end, as a peer that goes away.
@(private = "file")
hang_up :: proc(p: ^Pair) {
	net.close(p.client)
	p.client = NO_SOCKET
}

@(private = "file")
send :: proc(t: ^testing.T, p: ^Pair, data: string) {
	testing.expect(t, send_all(p.client, transmute([]u8)data))
}

@(test)
test_read_head :: proc(t: ^testing.T) {
	p := pair_open(t)
	defer pair_close(p)

	// A head that arrives in pieces.
	send(t, p, "GET /a HTTP/1.1\r\nHo")
	send(t, p, "st: x\r")
	send(t, p, "\n\r")
	send(t, p, "\n")
	head, ok := read_head(&p.server)
	testing.expect(t, ok)
	testing.expect_value(t, head, "GET /a HTTP/1.1\r\nHost: x")

	// Two requests in one send: the second stays buffered for the next read,
	// and so does the start of a body.
	send(t, p, "POST /b HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET /c HTTP/1.1\r\n\r\n")
	head, ok = read_head(&p.server)
	testing.expect(t, ok)
	testing.expect_value(t, head, "POST /b HTTP/1.1\r\nContent-Length: 5")
	body: [5]u8
	testing.expect(t, read_body(&p.server, body[:]))
	testing.expect_value(t, string(body[:]), "hello")
	head, ok = read_head(&p.server)
	testing.expect(t, ok)
	testing.expect_value(t, head, "GET /c HTTP/1.1")
}

@(test)
test_read_head_refuses :: proc(t: ^testing.T) {
	// A head that never ends doesn't use up more than the buffer.
	p := pair_open(t)
	defer pair_close(p)
	long := strings.repeat(
		"X-Padding: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n",
		300,
		context.temp_allocator,
	)
	send(t, p, "GET / HTTP/1.1\r\n")
	send(t, p, long)
	_, ok := read_head(&p.server)
	testing.expect(t, !ok, "a head over the limit was accepted")

	// A head that is just under the limit still fits.
	q := pair_open(t)
	defer pair_close(q)
	pad := strings.repeat(
		"a",
		MAX_HEAD - len("GET / HTTP/1.1\r\nX: \r\n\r\n"),
		context.temp_allocator,
	)
	send(
		t,
		q,
		strings.concatenate({"GET / HTTP/1.1\r\nX: ", pad, "\r\n\r\n"}, context.temp_allocator),
	)
	_, ok = read_head(&q.server)
	testing.expect(t, ok)

	// A peer that goes away before the end of its head.
	r := pair_open(t)
	defer pair_close(r)
	send(t, r, "GET / HTTP/1.1\r\nHost: x")
	hang_up(r)
	_, ok = read_head(&r.server)
	testing.expect(t, !ok)
}

@(test)
test_read_some_and_body :: proc(t: ^testing.T) {
	p := pair_open(t)
	defer pair_close(p)

	send(t, p, "GET / HTTP/1.1\r\n\r\nabcdefgh")
	_, ok := read_head(&p.server)
	testing.expect(t, ok)
	// What is buffered comes first, in as many pieces as asked for.
	out: [3]u8
	n: int
	n, ok = read_some(&p.server, out[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(out[:n]), "abc")
	n, ok = read_some(&p.server, out[:0])
	testing.expect(t, ok)
	testing.expect_value(t, n, 0)
	rest: [5]u8
	testing.expect(t, read_body(&p.server, rest[:]))
	testing.expect_value(t, string(rest[:]), "defgh")

	// A body that is cut short.
	send(t, p, "xyz")
	hang_up(p)
	long: [10]u8
	testing.expect(t, !read_body(&p.server, long[:]))
	_, ok = read_some(&p.server, out[:])
	testing.expect(t, !ok)
}

@(private = "file")
read_all :: proc(t: ^testing.T, sock: net.TCP_Socket) -> string {
	data := make([dynamic]u8, context.temp_allocator)
	buf: [1024]u8
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if err != nil || n == 0 {
			break
		}
		append(&data, ..buf[:n])
	}
	return string(data[:])
}

@(test)
test_respond :: proc(t: ^testing.T) {
	p := pair_open(t)
	testing.expect(t, respond(p.server.sock, 404, "application/json", `{"error":"x"}`))
	testing.expect(
		t,
		respond(
			p.server.sock,
			200,
			"text/plain",
			"hi",
			keep_alive = true,
			extra = "X-Extra: 1\r\n",
		),
	)
	net.close(p.server.sock)
	p.server.sock = NO_SOCKET
	got := read_all(t, p.client)
	defer pair_close(p)

	first_end := strings.index(got, `{"error":"x"}`) + len(`{"error":"x"}`)
	first, second := got[:first_end], got[first_end:]
	testing.expect(t, strings.has_prefix(first, "HTTP/1.1 404 Not Found\r\n"))
	testing.expect(t, strings.contains(first, "Content-Type: application/json\r\n"))
	testing.expect(t, strings.contains(first, "Content-Length: 13\r\n"))
	testing.expect(t, strings.contains(first, "Connection: close\r\n"))
	testing.expect(t, strings.has_suffix(first, "\r\n\r\n{\"error\":\"x\"}"))

	testing.expect(t, strings.has_prefix(second, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(second, "Connection: keep-alive\r\n"))
	testing.expect(t, strings.contains(second, "X-Extra: 1\r\n"))
	testing.expect(t, strings.contains(second, "Content-Length: 2\r\n"))
	testing.expect(t, strings.has_suffix(second, "\r\n\r\nhi"))
	// The headers end with an empty line, once.
	testing.expect_value(t, strings.count(second, "\r\n\r\n"), 1)
}

// ---- WebSocket frames ----

@(private = "file")
frame_to_server :: proc(
	t: ^testing.T,
	p: ^Pair,
	op: Opcode,
	payload: []u8,
	mask := [4]u8{0x12, 0x34, 0x56, 0x78},
) {
	// write_frame masks in place.
	copied := make([]u8, len(payload), context.temp_allocator)
	copy(copied, payload)
	testing.expect(t, write_frame(p.client, op, copied, mask))
}

@(test)
test_websocket_client_frames :: proc(t: ^testing.T) {
	p := pair_open(t)
	defer pair_close(p)
	buf := make([]u8, MAX_FRAME, context.temp_allocator)

	// Sizes around where the length takes more bytes.
	for size in ([]int{0, 1, 125, 126, 127, 1000, 65535, MAX_FRAME}) {
		payload := make([]u8, size, context.temp_allocator)
		for &b, i in payload {
			b = u8(i * 7 + size)
		}
		frame_to_server(t, p, .Binary, payload)
		op, n, ok := read_frame(&p.server, buf)
		testing.expectf(t, ok, "a frame of %d bytes was refused", size)
		testing.expect_value(t, op, Opcode.Binary)
		testing.expect_value(t, n, size)
		testing.expectf(t, string(buf[:n]) == string(payload), "a frame of %d bytes changed", size)
	}

	// Control frames and text.
	frame_to_server(t, p, .Ping, []u8{1, 2, 3})
	frame_to_server(t, p, .Text, transmute([]u8)string("hello"))
	frame_to_server(t, p, .Close, nil)
	op, n, ok := read_frame(&p.server, buf)
	testing.expect(t, ok)
	testing.expect_value(t, op, Opcode.Ping)
	testing.expect_value(t, n, 3)
	op, n, ok = read_frame(&p.server, buf)
	testing.expect(t, ok)
	testing.expect_value(t, op, Opcode.Text)
	testing.expect_value(t, string(buf[:n]), "hello")
	op, n, ok = read_frame(&p.server, buf)
	testing.expect(t, ok)
	testing.expect_value(t, op, Opcode.Close)
	testing.expect_value(t, n, 0)

	// Every byte of the mask is used.
	frame_to_server(t, p, .Binary, []u8{1, 2, 3, 4, 5, 6, 7, 8}, {0xff, 0, 0xf0, 0x0f})
	_, n, ok = read_frame(&p.server, buf)
	testing.expect(t, ok)
	testing.expect_value(t, string(buf[:n]), "\x01\x02\x03\x04\x05\x06\x07\x08")
}

@(test)
test_websocket_server_frames :: proc(t: ^testing.T) {
	p := pair_open(t)
	defer pair_close(p)
	buf: [1000]u8

	// A server's frames are not masked, and it is those a client reads.
	payload := make([]u8, 300, context.temp_allocator)
	for &b, i in payload {
		b = u8(i)
	}
	testing.expect(t, write_frame(p.server.sock, .Binary, payload))
	client := Conn {
		sock = p.client,
	}
	op, n, ok := read_frame(&client, buf[:], from_server = true)
	testing.expect(t, ok)
	testing.expect_value(t, op, Opcode.Binary)
	testing.expect_value(t, n, 300)
	testing.expect_value(t, string(buf[:n]), string(payload))

	// A masked frame read as a server's, and an unmasked one read as a
	// client's, are refused.
	q := pair_open(t)
	defer pair_close(q)
	frame_to_server(t, q, .Binary, []u8{1})
	_, _, ok = read_frame(&q.server, buf[:], from_server = true)
	testing.expect(t, !ok)
	r := pair_open(t)
	defer pair_close(r)
	testing.expect(t, write_frame(r.server.sock, .Binary, []u8{1}))
	_, _, ok = read_frame(&Conn{sock = r.client}, buf[:])
	testing.expect(t, !ok)
}

@(test)
test_websocket_frames_are_refused :: proc(t: ^testing.T) {
	buf := make([]u8, 200, context.temp_allocator)
	Case :: struct {
		name:  string,
		bytes: []u8,
	}
	// What a peer could send that isn't a frame we accept.
	cases := []Case {
		{"unmasked", {0x82, 0x01, 0x41}},
		{"fragment", {0x02, 0x81, 0, 0, 0, 0, 0x41}}, // FIN not set
		{"larger than the buffer", {0x82, 0xfe, 0x00, 0xc9, 0, 0, 0, 0}}, // 201 bytes into 200
		{"larger than MAX_FRAME", {0x82, 0xfe, 0xff, 0xff, 0, 0, 0, 0}},
		{
			"a huge 64-bit length",
			{0x82, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0},
		},
		{"a 64-bit length of 2^32", {0x82, 0xff, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0}},
		{"cut in the header", {0x82}},
		{"cut in the length", {0x82, 0xfe, 0x00}},
		{"cut in the mask", {0x82, 0x81, 1, 2}},
		{"cut in the payload", {0x82, 0x85, 1, 2, 3, 4, 9, 9}},
		{"nothing", {}},
	}
	for c in cases {
		p := pair_open(t)
		if len(c.bytes) > 0 {
			testing.expect(t, send_all(p.client, c.bytes))
		}
		net.shutdown(p.client, .Send)
		_, _, ok := read_frame(&p.server, buf)
		testing.expectf(t, !ok, "%s was accepted", c.name)
		pair_close(p)
	}
}

@(test)
test_read_exact :: proc(t: ^testing.T) {
	p := pair_open(t)
	defer pair_close(p)
	send(t, p, "0123456789")
	a, b: [4]u8
	testing.expect(t, read_exact(&p.server, a[:]))
	testing.expect(t, read_exact(&p.server, b[:]))
	testing.expect_value(t, string(a[:]), "0123")
	testing.expect_value(t, string(b[:]), "4567")
	testing.expect(t, read_exact(&p.server, nil))
	// Two bytes are left, and the peer says it is done.
	net.shutdown(p.client, .Send)
	testing.expect(t, !read_exact(&p.server, a[:]))
}

@(test)
test_websocket_masking_is_in_place :: proc(t: ^testing.T) {
	// write_frame masks the payload it is given, which a caller that wants the
	// original afterwards has to know.
	p := pair_open(t)
	defer pair_close(p)
	payload := []u8{1, 2, 3, 4}
	testing.expect(t, write_frame(p.client, .Binary, payload, [4]u8{0xaa, 0xaa, 0xaa, 0xaa}))
	testing.expect_value(t, payload[0], u8(1 ~ 0xaa))
	// Without a mask it is left alone.
	other := []u8{1, 2, 3, 4}
	testing.expect(t, write_frame(p.server.sock, .Binary, other))
	testing.expect_value(t, other[0], u8(1))
}
