#+build !wasi
package script

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "client:conn"

// A small HTTP server for the tests: the same few pages as docs/examples, one
// connection at a time, each answered and closed.
@(private = "file")
Server :: struct {
	socket:  net.TCP_Socket,
	port:    int,
	stop:    bool,
	thread:  ^thread.Thread,
	posted:  string, // what the last POST had, with its content type (owned)
	mutex:   sync.Mutex,
}

@(private = "file")
server_start :: proc() -> (s: ^Server, ok: bool) {
	s = new(Server)
	socket, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil {
		free(s)
		return nil, false
	}
	s.socket = socket
	ep, _ := net.bound_endpoint(socket)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, server_loop, context)
	return s, true
}

@(private = "file")
server_stop :: proc(s: ^Server) {
	s.stop = true
	// Wake the accept with a connection of our own.
	if c, err := net.dial_tcp({address = net.IP4_Loopback, port = s.port}); err == nil {
		net.close(c)
	}
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.socket)
	delete(s.posted)
	free(s)
}

@(private = "file")
server_loop :: proc(s: ^Server) {
	for !s.stop {
		client, _, err := net.accept_tcp(s.socket)
		if err != nil {
			continue
		}
		if s.stop {
			net.close(client)
			break
		}
		serve(s, client)
		net.close(client)
	}
}

@(private = "file")
serve :: proc(s: ^Server, client: net.TCP_Socket) {
	buf: [8192]u8
	total := 0
	// Until the end of the headers, and then the body it announces.
	for total < len(buf) {
		n, err := net.recv_tcp(client, buf[total:])
		if err != nil || n == 0 {
			break
		}
		total += n
		text := string(buf[:total])
		end := strings.index(text, "\r\n\r\n")
		if end < 0 {
			continue
		}
		length := 0
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(strings.to_lower(line, context.temp_allocator), "content-length:") {
				length, _ = strconv.parse_int(strings.trim_space(line[len("content-length:"):]))
			}
		}
		if total < end + 4 + length {
			continue
		}
		break
	}
	request := string(buf[:total])
	line, _, _ := strings.partition(request, "\r\n")
	parts := strings.split(line, " ", context.temp_allocator)
	if len(parts) < 2 {
		return
	}
	method, path := parts[0], parts[1]
	headers := request[len(line):]
	body := ""
	if i := strings.index(request, "\r\n\r\n"); i >= 0 {
		body = request[i + 4:]
	}

	reply :: proc(client: net.TCP_Socket, status: string, extra: string, body: string) {
		head := fmt.tprintf("HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n", status, len(body), extra)
		net.send_tcp(client, transmute([]u8)head)
		// In pieces, so that a large body is sent whole.
		sent := 0
		for sent < len(body) {
			n, err := net.send_tcp(client, transmute([]u8)body[sent:])
			if err != nil {
				return
			}
			sent += n
		}
	}
	switch {
	case method == "GET" && path == "/small":
		reply(client, "200 OK", "Content-Type: text/plain\r\nX-Multi: 1\r\nX-Multi: 2\r\n", "hello from the server")
	case method == "GET" && path == "/missing":
		reply(client, "404 Not Found", "", "nothing here")
	case method == "GET" && path == "/big":
		reply(client, "200 OK", "", strings.repeat("x", 3 * 1024 * 1024, context.temp_allocator))
	case method == "GET" && path == "/hop":
		reply(client, "302 Found", "Location: /small\r\n", "")
	case method == "GET" && path == "/to-file":
		reply(client, "302 Found", "Location: file:///etc/hostname\r\n", "")
	case method == "GET" && path == "/slow":
		time.sleep(3 * time.Second)
		reply(client, "200 OK", "", "late")
	case method == "POST" && path == "/echo":
		type := "?"
		for h in strings.split_lines(headers, context.temp_allocator) {
			if strings.has_prefix(strings.to_lower(h, context.temp_allocator), "content-type:") {
				type = strings.trim_space(h[len("content-type:"):])
			}
		}
		auth := ""
		for h in strings.split_lines(headers, context.temp_allocator) {
			if strings.has_prefix(strings.to_lower(h, context.temp_allocator), "x-token:") {
				auth = strings.trim_space(h[len("x-token:"):])
			}
		}
		reply(client, "200 OK", "", fmt.tprintf("%s|%s|%s", type, auth, body))
	case:
		reply(client, "404 Not Found", "", "?")
	}
}

@(test)
test_web_requests_for_real :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	if !http_ready(r.rt) {
		log_skip(t, "no way to make web requests here (libcurl?)")
		return
	}
	server, ok := server_start()
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer server_stop(server)

	base := fmt.tprintf("http://127.0.0.1:%d", server.port)
	source, _ := strings.replace_all(
		`
		BASE = "BASE_URL"
		answers = {}
		local function save(name) return function(r) answers[name] = r end end
		function go()
			yap.http_get(BASE .. "/small", save("small"))
			yap.http_get(BASE .. "/missing", save("missing"))
			yap.http_post(BASE .. "/echo", '{"a":1}', save("echo"),
				{ content_type = "application/json", headers = { ["X-Token"] = "abc" } })
			yap.http_get(BASE .. "/hop", save("hop"))
		end
		function go_more()
			yap.http_get(BASE .. "/big", save("big"))
			yap.http_get(BASE .. "/to-file", save("to_file"))
			yap.http_get("http://127.0.0.1:1/refused", save("refused"))
			yap.http_get(BASE .. "/slow", save("slow"), { timeout = 1 })
		end
		function check_first()
			local a = answers.small
			assert(a and a.ok and a.status == 200 and a.body == "hello from the server", "small")
			assert(a.headers["content-type"] == "text/plain" and a.headers["x-multi"] == "1, 2", "its headers")
			assert(answers.missing.ok and answers.missing.status == 404 and answers.missing.body == "nothing here", "missing")
			assert(answers.echo.body == 'application/json|abc|{"a":1}', answers.echo.body)
			assert(answers.hop.ok and answers.hop.body == "hello from the server", "a redirect is followed")
		end
		function check_more()
			assert(answers.big and not answers.big.ok and answers.big.error:find("too large"), "big")
			assert(answers.big.body == nil)
			assert(answers.to_file and not answers.to_file.ok and answers.to_file.status ~= 200, "a redirect to a file")
			assert(answers.refused and not answers.refused.ok and answers.refused.error ~= "", "refused")
			assert(answers.slow and not answers.slow.ok and answers.slow.error == "timed out", "slow")
		end
		yap.log("net available:", yap.http_available())
		`,
		"BASE_URL",
		base,
		context.temp_allocator,
	)
	started := runtime_add(r.rt, "net.lua", source, Script_Config{permissions = {"net"}})
	if len(r.rt.items) > 0 {
		testing.expectf(t, started, "net.lua: %s", r.rt.items[0].problem)
	}
	if !started {
		return
	}
	s := r.rt.entries[0].script

	run_until :: proc(t: ^testing.T, r: ^Rig, s: ^Script, done: proc(s: ^Script) -> bool) {
		began := time.tick_now()
		for !done(s) && time.tick_since(began) < 8 * time.Second {
			runtime_step(r.rt, 5 * time.Millisecond)
			time.sleep(2 * time.Millisecond)
		}
		testing.expect(t, done(s), "the requests were not answered in time")
	}
	idle :: proc(s: ^Script) -> bool {
		return len(s.requests) == 0 && len(s.completions) == 0 && pending(s) == 0
	}

	// A check is a handler run here, so that a wrong answer fails the test.
	check :: proc(t: ^testing.T, s: ^Script, name: string) {
		_, _ = call(s, name)
		results: [dynamic]Result
		defer {
			results_clear(&results)
			delete(results)
		}
		for pending(s) > 0 {
			step(s, 5 * time.Millisecond, &results)
		}
		for res in results {
			testing.expectf(t, res.status == .Finished, "%s: %v: %v", name, res.name, res.message)
		}
	}

	_, _ = call(s, "go")
	run_until(t, &r, s, idle)
	check(t, s, "check_first")

	_, _ = call(s, "go_more")
	run_until(t, &r, s, idle)
	check(t, s, "check_more")
}

// The example in docs/examples/scripts, against the same server.
WEBGET :: #load("../../../docs/examples/scripts/webget.lua", string)

@(test)
test_the_webget_example :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)

	info, has, err := read_info("webget.lua", WEBGET)
	testing.expect(t, has)
	testing.expect_value(t, err, "")
	testing.expect_value(t, info.permissions, Permissions{.Notify, .Net})
	testing.expect_value(t, len(info.problems), 0)
	info_destroy(&info)

	if !http_ready(r.rt) {
		log_skip(t, "no way to make web requests here (libcurl?)")
		return
	}
	server, ok := server_start()
	if !ok {
		testing.expect(t, ok)
		return
	}
	defer server_stop(server)
	base := fmt.tprintf("http://127.0.0.1:%d", server.port)

	testing.expect(t, runtime_add(r.rt, "webget.lua", WEBGET, Script_Config{permissions = {"notify", "net"}}))
	s := r.rt.entries[0].script
	last :: proc(s: ^Script) -> string {
		text, _ := s.store["last"].(string)
		return text
	}
	ask :: proc(t: ^testing.T, r: ^Rig, s: ^Script, line: string, want: string) {
		testing.expect(t, runtime_run_command(r.rt, r.a, line, "general"))
		began := time.tick_now()
		for time.tick_since(began) < 5 * time.Second {
			runtime_step(r.rt, 5 * time.Millisecond)
			time.sleep(2 * time.Millisecond)
			if strings.has_prefix(last(s), want) {
				return
			}
		}
		testing.expectf(t, strings.has_prefix(last(s), want), "after %q: %q (wanted %q)", line, last(s), want)
	}
	ask(t, &r, s, fmt.tprintf("/get %s/small", base), "200 hello from the server")
	ask(t, &r, s, fmt.tprintf("/get %s/missing", base), "404 nothing here")
	ask(t, &r, s, fmt.tprintf("/post %s/echo hello there", base), "200 text/plain||hello there")
	ask(t, &r, s, "/get http://127.0.0.1:1/", "failed: ")
	ask(t, &r, s, fmt.tprintf("/get %s/big", base), "failed: the answer is too large")
	// Both of these only tell the user what to do.
	testing.expect(t, runtime_run_command(r.rt, r.a, "/get", "general"))
	testing.expect(t, runtime_run_command(r.rt, r.a, "/post onlyanaddress", "general"))
	runtime_step(r.rt, 10 * time.Millisecond)
}

@(private = "file")
log_skip :: proc(t: ^testing.T, why: string) {
	fmt.printfln("skipped: %s", why)
}

_ :: conn.Event_Message

@(test)
test_web_requests_without_a_client :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
	// As on Linux without libcurl: there is no client.
	client := r.rt.http.client
	r.rt.http.client = nil
	defer r.rt.http.client = client
	ok, how := runtime_http_status(r.rt)
	testing.expect(t, !ok)
	testing.expect(t, how != "")

	testing.expect(
		t,
		runtime_add(
			r.rt,
			"nonet.lua",
			`
			function go() yap.http_get("http://127.0.0.1:1/", function(r) answer = r end) end
			function check()
				assert(yap.http_available() == false)
				assert(answer and answer.ok == false and answer.error:find("libcurl") and answer.status == nil, "answer")
			end`,
			Script_Config{permissions = {"net"}},
		),
	)
	s := r.rt.entries[0].script
	_, _ = call(s, "go")
	results: [dynamic]Result
	defer {
		results_clear(&results)
		delete(results)
	}
	for _ in 0 ..< 5 {
		runtime_step(r.rt, 5 * time.Millisecond)
	}
	_, _ = call(s, "check")
	for pending(s) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	for res in results {
		testing.expectf(t, res.status == .Finished, "%v: %v", res.name, res.message)
	}
	testing.expect_value(t, len(r.rt.http.pending), 0)
}
