#+build !wasi
package script

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "client:conn"

// A small HTTP server for the tests: a few pages, each connection answered and
// closed. A connection is served on a thread of its own and gives up when nothing
// comes for a while: a client may open a connection it never uses (CFNetwork does),
// and that must not hold up the next one or the end of the test.
@(private = "file")
Server :: struct {
	socket:    net.TCP_Socket,
	port:      int,
	stop:      bool,
	acceptor:  ^thread.Thread,
	posted:    string, // the body of the last POST (owned, by `allocator`)
	allocator: runtime.Allocator,
	mutex:     sync.Mutex, // for `posted` and `handlers`
	handlers:  [dynamic]^thread.Thread,
}

@(private = "file")
Handler :: struct {
	server: ^Server,
	client: net.TCP_Socket,
}

// How long a connection may be silent.
@(private = "file")
IDLE :: 2 * time.Second

@(private = "file")
server_start :: proc() -> (s: ^Server, ok: bool) {
	s = new(Server)
	s.allocator = context.allocator
	socket, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		free(s)
		return nil, false
	}
	s.socket = socket
	ep, _ := net.bound_endpoint(socket)
	s.port = ep.port
	s.acceptor = thread.create_and_start_with_poly_data(s, server_loop, context)
	return s, true
}

@(private = "file")
server_stop :: proc(s: ^Server) {
	s.stop = true
	// Wake the accept with a connection of our own, and close the socket, so that
	// it can't stay blocked whichever of the two a system takes notice of.
	if c, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = s.port}); err == nil {
		net.close(c)
	}
	net.close(s.socket)
	thread.join(s.acceptor)
	thread.destroy(s.acceptor)
	for h in s.handlers {
		thread.join(h) // they give up when nothing comes
		thread.destroy(h)
	}
	delete(s.handlers)
	delete(s.posted, s.allocator)
	free(s)
}

@(private = "file")
server_loop :: proc(s: ^Server) {
	// The thread's own temp allocator, not the one of the thread that made it.
	context.temp_allocator = runtime.default_context().temp_allocator
	for !s.stop {
		client, _, err := net.accept_tcp(s.socket)
		if err != nil {
			time.sleep(10 * time.Millisecond)
			continue
		}
		if s.stop {
			net.close(client)
			break
		}
		net.set_option(client, .Receive_Timeout, IDLE)
		h := new(Handler)
		h^ = {s, client}
		t := thread.create_and_start_with_poly_data(h, handle, context)
		sync.guard(&s.mutex)
		append(&s.handlers, t)
	}
}

@(private = "file")
handle :: proc(h: ^Handler) {
	context.temp_allocator = runtime.default_context().temp_allocator
	serve(h.server, h.client)
	// A lingering close: say that nothing more comes, and read what the client still
	// sends until it closes. Closing at once can reset the connection, and a reset
	// throws away what has not been delivered yet.
	net.shutdown(h.client, .Send)
	scratch: [1024]u8
	for {
		n, err := net.recv_tcp(h.client, scratch[:])
		if err != nil || n == 0 {
			break
		}
	}
	net.close(h.client)
	free(h)
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
	case method == "GET" && path == "/medium":
		// Under the cap, but more than the socket buffers hold.
		reply(client, "200 OK", "Content-Type: text/plain\r\n", strings.repeat("m", 700 * 1024, context.temp_allocator))
	case method == "GET" && path == "/big-typed":
		reply(client, "200 OK", "Content-Type: text/plain\r\n", strings.repeat("x", 3 * 1024 * 1024, context.temp_allocator))
	case method == "GET" && path == "/hop":
		reply(client, "302 Found", "Location: /small\r\n", "")
	case method == "GET" && path == "/to-file":
		reply(client, "302 Found", "Location: file:///etc/hostname\r\n", "")
	case method == "GET" && path == "/slow":
		time.sleep(3 * time.Second)
		reply(client, "200 OK", "", "late")
	case method == "POST" && path == "/echo":
		sync.guard(&s.mutex)
		delete(s.posted, s.allocator)
		s.posted = strings.clone(body, s.allocator)
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
			yap.http_get(BASE .. "/big-typed", save("big_typed"))
			yap.http_get(BASE .. "/medium", save("medium"))
			yap.http_get(BASE .. "/to-file", save("to_file"))
		end
		-- (A script may have four requests out at once.)
		function go_rest()
			yap.http_get("http://127.0.0.1:1/refused", save("refused"))
			yap.http_get(BASE .. "/slow", save("slow"), { timeout = 1 })
		end
		-- What an answer was, for the message of a failed check.
		local function describe(r)
			if not r then return "no answer" end
			return "ok=" .. tostring(r.ok) .. " status=" .. tostring(r.status) .. " error=" .. tostring(r.error)
				.. " body=" .. tostring(r.body and #r.body) .. " bytes"
		end
		-- Every check is reported, not only the first that fails: some systems can only be
		-- tried through the tests, and one run should show everything.
		local problems
		local function expect(cond, message) if not cond then problems[#problems + 1] = message end end
		local function report() assert(#problems == 0, table.concat(problems, "; ")) end
		function check_first()
			problems = {}
			local a = answers.small
			expect(a and a.ok and a.status == 200 and a.body == "hello from the server", "small: " .. describe(a))
			if a and a.headers then
				-- A header that comes twice is joined; how is up to the library the system has.
				local multi = a.headers["x-multi"] or ""
				expect(a.headers["content-type"] == "text/plain", "content-type is " .. tostring(a.headers["content-type"]))
				expect(multi:find("1", 1, true) and multi:find("2", 1, true), "x-multi is " .. multi)
			end
			local m = answers.missing
			expect(m and m.ok and m.status == 404 and m.body == "nothing here", "missing: " .. describe(m))
			expect(answers.echo and answers.echo.body == 'application/json|abc|{"a":1}', "echo: " .. describe(answers.echo) .. " " .. tostring(answers.echo and answers.echo.body))
			expect(answers.hop and answers.hop.ok and answers.hop.body == "hello from the server", "a redirect is followed: " .. describe(answers.hop))
			report()
		end
		function check_more()
			problems = {}
			for _, name in ipairs({ "big", "big_typed" }) do
				local big = answers[name]
				expect(big and not big.ok and big.error:find("too large") and big.body == nil, name .. ": " .. describe(big))
			end
			local medium = answers.medium
			expect(medium and medium.ok and medium.status == 200 and #medium.body == 700 * 1024, "medium: " .. describe(medium))
			local file = answers.to_file
			expect(file and not file.ok and file.status ~= 200, "a redirect to a file: " .. describe(file))
			local refused = answers.refused
			expect(refused and not refused.ok and refused.error ~= "", "refused: " .. describe(refused))
			local slow = answers.slow
			expect(slow and not slow.ok and slow.error == "timed out", "slow: " .. describe(slow))
			report()
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
	_, _ = call(s, "go_rest")
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

@(test)
test_the_webhook_example :: proc(t: ^testing.T) {
	f := folder_make()
	defer folder_destroy(&f)
	r := rig_new(f.dir)
	defer rig_destroy(&r)
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
	testing.expect(t, runtime_add(r.rt, "webhook.lua", WEBHOOK_EXAMPLE, Script_Config{permissions = {"net"}}))
	s := r.rt.entries[0].script

	hear :: proc(r: ^Rig, e: conn.Event) {
		emit(r.a, e)
		for _ in 0 ..< 3 {
			runtime_step(r.rt, 10 * time.Millisecond)
		}
	}
	posted_body :: proc(server: ^Server) -> string {
		sync.guard(&server.mutex)
		return strings.clone(server.posted, context.temp_allocator)
	}
	wait_for_post :: proc(r: ^Rig, server: ^Server) -> string {
		began := time.tick_now()
		for time.tick_since(began) < 4 * time.Second {
			runtime_step(r.rt, 5 * time.Millisecond)
			time.sleep(2 * time.Millisecond)
			if body := posted_body(server); body != "" {
				return body
			}
		}
		return ""
	}

	// No address yet: nothing is sent.
	hear(&r, message("hello @me", true))
	testing.expect_value(t, len(s.requests), 0)

	testing.expect_value(t, runtime_set_value(r.rt, "webhook.lua", "url", fmt.tprintf("http://127.0.0.1:%d/echo", server.port)), "")
	// Not a mention, or our own: nothing.
	hear(&r, message("hello"))
	mine := message("hi @me", true).(conn.Event_Message)
	mine.mine = true
	hear(&r, mine)
	testing.expect_value(t, len(s.requests), 0)

	// A mention, with a quote, a line break and a backslash in it.
	e := message("he said \"hi\"\nand left\\", true)
	hear(&r, e)
	body := wait_for_post(&r, server)
	testing.expect(t, body != "", "no request arrived")
	if body == "" {
		return
	}
	parsed, err := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	testing.expectf(t, err == nil, "not JSON: %s", body)
	obj, is_object := parsed.(json.Object)
	testing.expect(t, is_object)
	field :: proc(obj: json.Object, key: string) -> string {
		text, _ := obj[key].(json.String)
		return string(text)
	}
	testing.expect_value(t, field(obj, "author"), "Ann")
	testing.expect_value(t, field(obj, "channel"), "general")
	testing.expect_value(t, field(obj, "server"), "a.example:7777")
	testing.expect_value(t, field(obj, "text"), "he said \"hi\"\nand left\\")
}
