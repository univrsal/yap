package server

import "core:crypto/ecdh"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "common:proto"
import "lib:gateway"
import "lib:http"
import "lib:lite"

// Tests of the bot API's gateway (lib/gateway). They cover the whole path
// from HTTP to the gateway, to the server and back, all in one process:
// - The server's packet handling and syncs run on a loopback socket (the lt_
//   procedures from lite_test.odin) and are driven by the test's thread.
// - The gateway runs on its own threads, and its HTTP side sits behind a
//   listener that is owned by the test.
// - A bot's requests are made from another thread, which waits for each answer
//   while the test's thread keeps the server running.

// Call is an HTTP request that a test makes, together with the response.
@(private = "file")
Call :: struct {
	method: string,
	path:   string,
	token:  string, // "" for no token
	body:   string,
	header: string, // more header lines, each ending in CRLF
	// The response.
	status: int,
	reply:  string, // owned
	allow:  string, // owned
	type:   string, // owned, the Content-Type header
	retry:  int, // the Retry-After header
}

@(private = "file")
Harness :: struct {
	g:        ^gateway.Gateway,
	listener: net.TCP_Socket,
	port:     int,
	accepter: ^thread.Thread,
	stopping: bool, // atomic
	// The HTTP threads are joined before the test ends. A thread that is still
	// freeing memory when the test's allocator is reset would corrupt it.
	mutex:    sync.Mutex,
	threads:  [dynamic]^thread.Thread,
	serving:  int, // atomic, the number of HTTP threads that are still running
}

// gt_open starts a gateway for the test's server and a listener for its
// HTTP side.
@(private = "file")
gt_open :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	h: ^Harness,
	idle: time.Duration = 0,
	settings := gateway.Config{},
) {
	ep, _ := net.bound_endpoint(ts.s.sock)
	cfg := settings
	cfg.server, cfg.idle = ep, idle
	ecdh.private_key_public_bytes(&ts.s.key, cfg.server_key[:])
	h.g = gateway.start(cfg)
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect_value(t, err, nil)
	h.listener = listener
	bound, _ := net.bound_endpoint(listener)
	h.port = bound.port
	h.accepter = thread.create_and_start_with_poly_data(h, gt_accept, init_context = context)
}

// gt_settle keeps the server running for a fixed amount of time. This is long
// enough for what the server sends to reach the gateway's thread, which checks
// every millisecond (or about every 15 ms on Windows).
@(private = "file")
gt_settle :: proc(ts: ^Test_Server) {
	start := time.tick_now()
	for time.tick_since(start) < 100 * time.Millisecond {
		lt_turn(ts)
	}
}

// gt_close stops everything that gt_open started, after the HTTP threads are
// done.
@(private = "file")
gt_close :: proc(ts: ^Test_Server, h: ^Harness) {
	sync.atomic_store(&h.stopping, true)
	// On Linux, closing the listener doesn't wake up an accept() that is
	// blocked on another thread. Instead the accepter is woken by a new
	// connection, which it recognizes as too late and drops.
	if wake, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, h.port}); err == nil {
		net.close(wake)
	}
	thread.join(h.accepter)
	thread.destroy(h.accepter)
	net.close(h.listener)
	for _ in 0 ..< 5000 {
		if sync.atomic_load(&h.serving) == 0 {
			break
		}
		lt_turn(ts)
	}
	for th in h.threads {
		thread.join(th)
		thread.destroy(th)
	}
	delete(h.threads)
	gateway.stop(h.g)
	// Handle whatever the connections sent while they were closing.
	lt_settle(ts)
}

@(private = "file")
gt_accept :: proc(h: ^Harness) {
	for !sync.atomic_load(&h.stopping) {
		sock, from, err := net.accept_tcp(h.listener)
		if err != nil {
			continue
		}
		if sync.atomic_load(&h.stopping) {
			net.close(sock)
			break
		}
		c := new(http.Conn)
		c.sock, c.remote = sock, from
		sync.atomic_add(&h.serving, 1)
		th := thread.create_and_start_with_poly_data2(h, c, proc(h: ^Harness, c: ^http.Conn) {
				defer sync.atomic_sub(&h.serving, 1)
				gateway.serve_connection(h.g, c)
			}, init_context = context)
		sync.guard(&h.mutex)
		append(&h.threads, th)
	}
}

// Script is a sequence of calls that another thread makes in order on one
// connection.
@(private = "file")
Script :: struct {
	port:  int,
	calls: []Call,
	done:  bool, // atomic
	ok:    bool, // whether every call got a response
}

// gt_calls makes `calls` in order on one keep-alive connection while this
// thread keeps the server running. It returns false if one of the calls got no
// response.
@(private = "file")
gt_calls :: proc(t: ^testing.T, ts: ^Test_Server, h: ^Harness, calls: []Call) -> bool {
	sc := Script {
		port  = h.port,
		calls = calls,
	}
	worker := thread.create_and_start_with_poly_data(&sc, gt_script, init_context = context)
	start := time.tick_now()
	for !sync.atomic_load(&sc.done) && time.tick_since(start) < 30 * time.Second {
		lt_turn(ts)
	}
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, sc.ok, "a call got no answer")
	return sc.ok
}

@(private = "file")
gt_script :: proc(sc: ^Script) {
	defer sync.atomic_store(&sc.done, true)
	sock, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, sc.port})
	if err != nil {
		return
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 10 * time.Second)
	c := new(http.Conn)
	defer free(c)
	c.sock = sock
	for &call in sc.calls {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%s %s HTTP/1.1\r\nHost: test\r\n", call.method, call.path)
		if call.token != "" {
			fmt.sbprintf(&b, "Authorization: Bot %s\r\n", call.token)
		}
		strings.write_string(&b, call.header)
		fmt.sbprintf(&b, "Content-Length: %d\r\n\r\n%s", len(call.body), call.body)
		if !http.send_all(sock, transmute([]u8)strings.to_string(b)) {
			return
		}
		head, ok := http.read_head(c)
		if !ok {
			return
		}
		// The status line ("HTTP/1.1 200 OK") followed by the headers.
		lines := strings.split_lines(head, context.temp_allocator)
		fields := strings.fields(lines[0], context.temp_allocator)
		call.status, _ = strconv.parse_int(fields[1])
		size := 0
		for line in lines[1:] {
			name, _, value := strings.partition(line, ": ")
			switch {
			case strings.equal_fold(name, "Content-Length"):
				size, _ = strconv.parse_int(value)
			case strings.equal_fold(name, "Allow"):
				call.allow = strings.clone(value)
			case strings.equal_fold(name, "Content-Type"):
				call.type = strings.clone(value)
			case strings.equal_fold(name, "Retry-After"):
				call.retry, _ = strconv.parse_int(value)
			}
		}
		body := make([]u8, size)
		if !http.read_body(c, body) {
			delete(body)
			return
		}
		call.reply = string(body)
	}
	sc.ok = true
}

@(private = "file")
calls_destroy :: proc(calls: []Call) {
	for c in calls {
		delete(c.reply)
		delete(c.allow)
		delete(c.type)
	}
}

// error_of returns the error code from an error response.
@(private = "file")
error_of :: proc(reply: string) -> string {
	e: gateway.Error_JSON
	if json.unmarshal(transmute([]u8)reply, &e, allocator = context.temp_allocator) != nil {
		return ""
	}
	return e.error
}

// gt_token returns the token of a bot whose account was created by `admin`.
// The token is owned by the caller because the temp allocations of the test
// are freed on every turn of the server.
@(private = "file")
gt_token :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	admin: ^Conn,
	username: string,
) -> (
	string,
	[proto.KEY_SIZE]u8,
) {
	token, pub, ok := proto.bot_token_make()
	testing.expect(t, ok)
	buf: [proto.BOT_BODY_MAX]u8
	status, _ := ts_ask(
		t,
		ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], username, "The Helper", pub, ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	return token, pub
}

@(private = "file")
gt_admin :: proc(t: ^testing.T, ts: ^Test_Server) -> ^Conn {
	ts_account(t, ts, "admin", "admin's password", {.Owner})
	admin := ts_connect(ts)
	status, _ := ts_login(t, ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	return admin
}

@(test)
test_gateway_token :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	unknown, _, _ := proto.bot_token_make()
	defer delete(unknown)
	calls := []Call {
		{method = "GET", path = "/api/v1/me", token = token},
		{method = "GET", path = "/api/v1/me", token = token},
		{method = "GET", path = "/api/v1/server"},
		{method = "GET", path = "/api/v1/me"},
		{method = "GET", path = "/api/v1/me", token = "not a token"},
		{method = "GET", path = "/api/v1/me", token = unknown},
		{method = "GET", path = "/api/v1/nothing", token = token},
		{method = "GET", path = "/api/v2/me", token = token},
		{method = "DELETE", path = "/api/v1/me", token = token},
		{method = "POST", path = "/api/v1/me", token = token, body = "{}"},
	}
	defer calls_destroy(calls)
	if !gt_calls(t, &ts, &h, calls) {
		return
	}

	// The token alone is enough to authenticate.
	testing.expect_value(t, calls[0].status, 200)
	me: gateway.Me_JSON
	testing.expect_value(
		t,
		json.unmarshal(transmute([]u8)calls[0].reply, &me, allocator = context.temp_allocator),
		nil,
	)
	u := conn_of(&ts.s, pub)
	testing.expect(t, u != nil && u.account != nil)
	if u != nil && u.account != nil {
		testing.expect_value(t, me.id, fmt.tprint(u.account.id))
	}
	testing.expect_value(t, me.username, "helper")
	testing.expect_value(t, me.display, "The Helper")
	testing.expect(t, me.bot)
	testing.expect(t, !me.owner)
	testing.expect_value(t, me.activity, "online")
	// The second request reuses the existing connection.
	testing.expect_value(t, calls[1].status, 200)
	testing.expect_value(t, calls[1].reply, calls[0].reply)

	// The server information is available to anyone.
	testing.expect_value(t, calls[2].status, 200)
	info: gateway.Server_JSON
	testing.expect_value(
		t,
		json.unmarshal(transmute([]u8)calls[2].reply, &info, allocator = context.temp_allocator),
		nil,
	)
	testing.expect(t, !info.registration.open)

	// A missing token, a malformed token and a token that belongs to nobody.
	for i in 3 ..= 5 {
		testing.expect_value(t, calls[i].status, 401)
		testing.expect_value(t, error_of(calls[i].reply), "unauthenticated")
	}
	// A path that doesn't exist and one that doesn't allow the method.
	testing.expect_value(t, calls[6].status, 404)
	testing.expect_value(t, error_of(calls[6].reply), "not_found")
	testing.expect_value(t, calls[7].status, 404)
	testing.expect_value(t, calls[8].status, 405)
	testing.expect_value(t, calls[8].allow, "GET, PATCH")
	testing.expect_value(t, calls[9].status, 405)

	// After logging out, the token stops working.
	out := []Call {
		{method = "POST", path = "/api/v1/logout", token = token},
		{method = "GET", path = "/api/v1/me", token = token},
	}
	defer calls_destroy(out)
	if gt_calls(t, &ts, &h, out) {
		testing.expect_value(t, out[0].status, 204)
		testing.expect_value(t, out[1].status, 401)
	}
	testing.expect(t, device_of(&ts.s.accounts, pub) == nil)
}

@(test)
test_gateway_login :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	admin := gt_admin(t, &ts)
	bot_token, _ := gt_token(t, &ts, admin, "helper")
	delete(bot_token)
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	calls := []Call {
		{
			method = "POST",
			path = "/api/v1/login",
			body = `{"username": "alice", "password": "wrong password"}`,
		},
		{method = "POST", path = "/api/v1/login", body = `{"username": "alice"}`},
		{method = "POST", path = "/api/v1/login", body = `not json`},
		// A bot has no password, so it can't log in with one.
		{
			method = "POST",
			path = "/api/v1/login",
			body = `{"username": "helper", "password": "anything at all"}`,
		},
		{
			method = "POST",
			path = "/api/v1/login",
			body = `{"username": "Alice", "password": "alice's password", "device": "weather cron"}`,
		},
	}
	defer calls_destroy(calls)
	if !gt_calls(t, &ts, &h, calls) {
		return
	}
	testing.expect_value(t, calls[0].status, 401)
	testing.expect_value(t, error_of(calls[0].reply), "wrong_password")
	testing.expect_value(t, calls[1].status, 400)
	testing.expect_value(t, calls[2].status, 400)
	testing.expect_value(t, calls[3].status, 401)
	testing.expect_value(t, calls[4].status, 200)
	got: gateway.Token_JSON
	testing.expect_value(
		t,
		json.unmarshal(transmute([]u8)calls[4].reply, &got, allocator = context.temp_allocator),
		nil,
	)
	key: ecdh.Private_Key
	if !testing.expect(t, proto.bot_token_parse(got.token, &key)) {
		return
	}
	alice_token := strings.clone(got.token)
	defer delete(alice_token)
	// The token is a device of her account with the requested name and the
	// gateway agent.
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(&key, pub[:])
	d := device_of(&ts.s.accounts, pub)
	testing.expect(t, d != nil)
	if d != nil {
		testing.expect_value(t, d.name, "weather cron")
		testing.expect_value(t, d.agent, gateway.AGENT)
	}

	// It works like any other token.
	me_calls := []Call{{method = "GET", path = "/api/v1/me", token = alice_token}}
	defer calls_destroy(me_calls)
	if gt_calls(t, &ts, &h, me_calls) {
		testing.expect_value(t, me_calls[0].status, 200)
		me: gateway.Me_JSON
		json.unmarshal(transmute([]u8)me_calls[0].reply, &me, allocator = context.temp_allocator)
		testing.expect_value(t, me.username, "alice")
		testing.expect_value(t, me.id, fmt.tprint(alice.id))
		testing.expect(t, !me.bot)
	}
}

@(test)
test_gateway_revoked :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	first := []Call{{method = "GET", path = "/api/v1/me", token = token}}
	defer calls_destroy(first)
	gt_calls(t, &ts, &h, first)
	testing.expect_value(t, first[0].status, 200)

	// After the token is revoked, the gateway is notified that it was logged out
	// and the token stops working.
	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ := ts_ask(t, &ts, admin, .Device_Revoke, proto.encode_device_revoke(buf[:], pub))
	testing.expect_value(t, status, proto.Status.Ok)
	start := time.tick_now()
	for conn_of(&ts.s, pub) != nil && time.tick_since(start) < 5 * time.Second {
		lt_turn(&ts)
	}
	testing.expect(t, conn_of(&ts.s, pub) == nil)
	after := []Call{{method = "GET", path = "/api/v1/me", token = token}}
	defer calls_destroy(after)
	gt_calls(t, &ts, &h, after)
	testing.expect_value(t, after[0].status, 401)
	testing.expect_value(t, error_of(after[0].reply), "unauthenticated")
}

@(test)
test_gateway_idle :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	h: Harness
	gt_open(t, &ts, &h, idle = 100 * time.Millisecond)
	defer gt_close(&ts, &h)

	calls := []Call{{method = "GET", path = "/api/v1/me", token = token}}
	defer calls_destroy(calls)
	gt_calls(t, &ts, &h, calls)
	testing.expect_value(t, calls[0].status, 200)
	testing.expect(t, conn_of(&ts.s, pub) != nil)

	// An unused connection is closed after a while, and the next request opens
	// a new one.
	start := time.tick_now()
	for conn_of(&ts.s, pub) != nil && time.tick_since(start) < 5 * time.Second {
		lt_turn(&ts)
	}
	testing.expect(t, conn_of(&ts.s, pub) == nil)
	again := []Call{{method = "GET", path = "/api/v1/me", token = token}}
	defer calls_destroy(again)
	gt_calls(t, &ts, &h, again)
	testing.expect_value(t, again[0].status, 200)
}

// The fields of the JSON response that the reading test checks.
@(private = "file")
Seen_Account :: struct {
	id:       string,
	username: string,
	bot:      bool,
	online:   bool,
}

@(private = "file")
Seen_Reaction :: struct {
	emoji: string,
	count: int,
	me:    bool,
}

@(private = "file")
Seen_Message :: struct {
	id:        string,
	content:   string,
	author:    Seen_Account,
	pinned:    bool,
	reactions: []Seen_Reaction,
}

@(private = "file")
Seen_Conv :: struct {
	id:              string,
	kind:            string,
	name:            string,
	home:            bool,
	member:          bool,
	recipient:       string,
	last_message_id: string,
	unread:          int,
	rights:          []string,
}

@(private = "file")
Seen_Role :: struct {
	id:          string,
	name:        string,
	color:       string,
	permissions: []string,
	mentionable: bool,
	everyone:    bool,
}

// gt_unmarshal parses a response into `v` using the temp allocator.
@(private = "file")
gt_unmarshal :: proc(t: ^testing.T, call: Call, v: ^$T) -> bool {
	err := json.unmarshal(transmute([]u8)call.reply, v, allocator = context.temp_allocator)
	return testing.expectf(
		t,
		err == nil,
		"%s %s: %v in %s",
		call.method,
		call.path,
		err,
		call.reply,
	)
}

// gt_post posts `text` to `conv` as `u` and returns the message's id.
@(private = "file")
gt_post :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	text: string,
) -> proto.Msg_Id {
	@(static) nonce: u64
	nonce += 1
	buf: [proto.MSG_POST_MAX_SIZE]u8
	status, body := ts_ask(
		t,
		ts,
		u,
		.Msg_Post,
		proto.encode_msg_post(buf[:], {conv = conv, nonce = nonce, kind = .Text, text = text}),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _, _ := proto.decode_msg_posted(body)
	return id
}

// gt_expect_ids checks that a page of history contains exactly those messages.
@(private = "file")
gt_expect_ids :: proc(t: ^testing.T, call: Call, ids: ..proto.Msg_Id) {
	page: []Seen_Message
	if !gt_unmarshal(t, call, &page) ||
	   !testing.expectf(t, len(page) == len(ids), "%s: %d messages", call.path, len(page)) {
		return
	}
	for id, i in ids {
		testing.expect_value(t, page[i].id, fmt.tprint(id))
	}
}

@(test)
test_gateway_reading :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	alice_conn := ts_connect(&ts)
	status, _ := ts_login(t, &ts, alice_conn, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	bot := device_of(&ts.s.accounts, pub).account
	home := ts.s.convs.home.id
	conv_member_add(&ts.s.convs, ts.s.convs.home, bot)

	// Create things to read: three messages (one pinned and one with a
	// reaction), a role and a DM from alice.
	first := gt_post(t, &ts, admin, home, "hello world")
	second := gt_post(t, &ts, admin, home, "an apple a day")
	third := gt_post(t, &ts, admin, home, "the third")
	pin_buf: [proto.MSG_PIN_SIZE]u8
	status, _ = ts_ask(t, &ts, admin, .Msg_Pin, proto.encode_msg_pin(&pin_buf, second, true))
	testing.expect_value(t, status, proto.Status.Ok)
	react_buf: [proto.MSG_REACT_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Msg_React,
		proto.encode_msg_react(&react_buf, first, "👍", true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	role_buf: [proto.ROLE_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Role_Set,
		proto.encode_role(
			role_buf[:],
			{
				name = "Helpers",
				perms = {.Pin_Messages},
				color = proto.ROLE_COLOR_SET | 0x3366ff,
				flags = {.Mentionable},
			},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id_buf: [4]u8
	dm_body: []u8
	status, dm_body = ts_ask(t, &ts, alice_conn, .DM_Open, proto.encode_account_id(&id_buf, bot))
	testing.expect_value(t, status, proto.Status.Ok)
	dm, _ := proto.decode_conv_id(dm_body)
	gt_post(t, &ts, alice_conn, dm, "hi helper")

	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)
	// Log in so that a snapshot of who is online is taken.
	warm := []Call{{method = "GET", path = "/api/v1/me", token = token}}
	defer calls_destroy(warm)
	gt_calls(t, &ts, &h, warm)
	gt_settle(&ts)

	// The paths are owned because every turn of the server frees the temp
	// allocator.
	paths := [?]string {
		"/api/v1/accounts",
		fmt.aprintf("/api/v1/accounts/%d", admin.account.id),
		"/api/v1/accounts/999",
		"/api/v1/accounts/abc",
		"/api/v1/roles",
		"/api/v1/convs",
		fmt.aprintf("/api/v1/convs/%d/messages", home),
		fmt.aprintf("/api/v1/convs/%d/messages?limit=1", home),
		fmt.aprintf("/api/v1/convs/%d/messages?before=%d&limit=1", home, third),
		fmt.aprintf("/api/v1/convs/%d/messages?after=%d", home, first),
		fmt.aprintf("/api/v1/convs/%d/messages?before=1&after=2", home),
		fmt.aprintf("/api/v1/convs/%d/pins", home),
		"/api/v1/search?q=apple",
		"/api/v1/convs/browse",
		fmt.aprintf("/api/v1/convs/%d/members", home),
		fmt.aprintf("/api/v1/messages/%d/reactions/%%F0%%9F%%91%%8D", first),
		fmt.aprintf("/api/v1/convs/%d", dm),
	}
	OWNED := bit_set[0 ..< 17]{1, 6, 7, 8, 9, 10, 11, 14, 15, 16}
	defer for p, i in paths {
		if i in OWNED {
			delete(p)
		}
	}
	calls := make([]Call, len(paths))
	defer delete(calls)
	defer calls_destroy(calls)
	for p, i in paths {
		calls[i] = {
			method = "GET",
			path   = p,
			token  = token,
		}
	}
	if !gt_calls(t, &ts, &h, calls) {
		return
	}
	for c, i in calls {
		want := 200
		switch i {
		case 2:
			want = 404
		case 3, 10:
			want = 400
		}
		testing.expectf(t, c.status == want, "%s: %d, not %d: %s", c.path, c.status, want, c.reply)
	}

	// All accounts, the online ones and a single account.
	accounts: []Seen_Account
	if gt_unmarshal(t, calls[0], &accounts) {
		names := make([dynamic]string, context.temp_allocator)
		for a in accounts {
			append(&names, a.username)
			if a.username == "helper" {
				testing.expect(t, a.bot)
				testing.expect(t, a.online)
			}
		}
		testing.expect_value(t, len(accounts), 3)
		testing.expect(t, slice_has(names[:], "admin") && slice_has(names[:], "alice"))
	}
	one: Seen_Account
	if gt_unmarshal(t, calls[1], &one) {
		testing.expect_value(t, one.username, "admin")
	}

	// The roles, with the role of everyone last.
	roles: []Seen_Role
	if gt_unmarshal(t, calls[4], &roles) && testing.expect_value(t, len(roles), 2) {
		testing.expect_value(t, roles[0].name, "Helpers")
		testing.expect_value(t, roles[0].color, "#3366ff")
		testing.expect(t, roles[0].mentionable)
		testing.expect(
			t,
			len(roles[0].permissions) == 1 && roles[0].permissions[0] == "pin_messages",
		)
		testing.expect(t, roles[1].everyone)
	}

	// The home channel and the DM, with their unread counts.
	convs: []Seen_Conv
	if gt_unmarshal(t, calls[5], &convs) && testing.expect_value(t, len(convs), 2) {
		testing.expect(t, convs[0].home)
		testing.expect_value(t, convs[0].kind, "channel")
		testing.expect_value(t, convs[0].last_message_id, fmt.tprint(third))
		testing.expect_value(t, convs[0].unread, 3)
		testing.expect_value(t, len(convs[0].rights), 7)
		testing.expect_value(t, convs[1].kind, "dm")
		// No voice in a DM.
		testing.expect_value(t, len(convs[1].rights), 6)
		testing.expect_value(t, convs[1].recipient, fmt.tprint(alice.id))
		testing.expect_value(t, convs[1].unread, 1)
	}

	// History from oldest to newest, and its pages.
	msgs: []Seen_Message
	if gt_unmarshal(t, calls[6], &msgs) && testing.expect_value(t, len(msgs), 3) {
		testing.expect_value(t, msgs[0].content, "hello world")
		testing.expect_value(t, msgs[0].author.username, "admin")
		testing.expect(t, len(msgs[0].reactions) == 1 && msgs[0].reactions[0].emoji == "👍")
		testing.expect(t, msgs[1].pinned)
		testing.expect_value(t, msgs[2].id, fmt.tprint(third))
	}
	gt_expect_ids(t, calls[7], third)
	gt_expect_ids(t, calls[8], second)
	gt_expect_ids(t, calls[9], second, third)
	gt_expect_ids(t, calls[11], second)

	// Search, browsing, members and reactors.
	found: struct {
		messages: []Seen_Message,
		more:     bool,
	}
	if gt_unmarshal(t, calls[12], &found) && testing.expect_value(t, len(found.messages), 1) {
		testing.expect_value(t, found.messages[0].id, fmt.tprint(second))
	}
	browsed: struct {
		convs: []Seen_Conv,
		more:  bool,
	}
	if gt_unmarshal(t, calls[13], &browsed) {
		gaming := false
		for c in browsed.convs {
			gaming ||= c.name == "Gaming" && !c.member
		}
		testing.expect(t, gaming)
	}
	members: []Seen_Account
	if gt_unmarshal(t, calls[14], &members) {
		helper := false
		for m in members {
			helper ||= m.username == "helper"
		}
		testing.expect(t, helper)
	}
	reactors: struct {
		total:    int,
		accounts: []Seen_Account,
	}
	if gt_unmarshal(t, calls[15], &reactors) {
		testing.expect_value(t, reactors.total, 1)
		testing.expect(t, len(reactors.accounts) == 1 && reactors.accounts[0].username == "admin")
	}
	dm_seen: Seen_Conv
	if gt_unmarshal(t, calls[16], &dm_seen) {
		testing.expect_value(t, dm_seen.recipient, fmt.tprint(alice.id))
	}

	// Later changes are picked up: a new message is the newest and is
	// unread.
	fourth := gt_post(t, &ts, admin, home, "one more")
	gt_settle(&ts)
	again := []Call{{method = "GET", path = "/api/v1/convs", token = token}}
	defer calls_destroy(again)
	if gt_calls(t, &ts, &h, again) && gt_unmarshal(t, again[0], &convs) && len(convs) == 2 {
		testing.expect_value(t, convs[0].last_message_id, fmt.tprint(fourth))
		testing.expect_value(t, convs[0].unread, 4)
	}
}

@(private = "file")
slice_has :: proc(s: []string, x: string) -> bool {
	for v in s {
		if v == x {
			return true
		}
	}
	return false
}

@(private = "file")
Seen_Me :: struct {
	id:       string,
	display:  string,
	status:   string,
	activity: string,
}

@(private = "file")
Seen_Post :: struct {
	id:               string,
	conv_id:          string,
	content:          string,
	author:           Seen_Account,
	edited_timestamp: string,
	deleted:          bool,
	pinned:           bool,
	reactions:        []Seen_Reaction,
	forwarded:        struct {
		author_id: string,
	},
}

// gt_run makes calls, each consisting of a method, a path and a body, with the
// token and checks the response of each. The responses are allocated with the
// temp allocator.
@(private = "file")
gt_run :: proc(t: ^testing.T, ts: ^Test_Server, h: ^Harness, token: string, steps: []struct {
		method, path, body: string,
		want:               int,
	}) -> []string {
	calls := make([]Call, len(steps))
	defer delete(calls)
	defer calls_destroy(calls)
	for s, i in steps {
		calls[i] = {
			method = s.method,
			path   = s.path,
			body   = s.body,
			token  = token,
		}
	}
	if !gt_calls(t, ts, h, calls) {
		return nil
	}
	replies := make([]string, len(calls), context.temp_allocator)
	for c, i in calls {
		testing.expectf(
			t,
			c.status == steps[i].want,
			"%s %s: %d, not %d: %s",
			c.method,
			c.path,
			c.status,
			steps[i].want,
			c.reply,
		)
		replies[i] = strings.clone(c.reply, context.temp_allocator)
	}
	return replies
}

@(private = "file")
gt_json :: proc(t: ^testing.T, reply: string, v: ^$T) -> bool {
	err := json.unmarshal(transmute([]u8)reply, v, allocator = context.temp_allocator)
	return testing.expectf(t, err == nil, "%v in %s", err, reply)
}

@(test)
test_gateway_writing :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	bot := device_of(&ts.s.accounts, pub).account
	conv_member_add(&ts.s.convs, ts.s.convs.home, bot)
	home := ts.s.convs.home.id
	gaming := conv_by_name(&ts.s.convs, "Gaming").id
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	// The paths are kept because every turn of the server frees the temp
	// allocator.
	owned := make([dynamic]string)
	defer {
		for p in owned {
			delete(p)
		}
		delete(owned)
	}
	at :: proc(owned: ^[dynamic]string, format: string, args: ..any) -> string {
		p := fmt.aprintf(format, ..args)
		append(owned, p)
		return p
	}
	home_messages := at(&owned, "/api/v1/convs/%d/messages", home)

	// Posting, posting the same message again and requests that are not valid
	// posts.
	r := gt_run(
	t,
	&ts,
	&h,
	token,
	{
		{"POST", home_messages, `{"content": "hello @alice", "nonce": "one"}`, 201},
		{"POST", home_messages, `{"content": "hello @alice", "nonce": "one"}`, 201},
		{"POST", home_messages, `{}`, 400},
		{"POST", home_messages, `{"content": 5}`, 400},
		{"POST", home_messages, `not json`, 400},
		{"POST", home_messages, `{"content": "x", "attachments": ["1"]}`, 404}, // the upload doesn't exist
	},
	)
	if r == nil {
		return
	}
	post, again: Seen_Post
	if !gt_json(t, r[0], &post) || !gt_json(t, r[1], &again) {
		return
	}
	testing.expect_value(t, post.author.username, "helper")
	testing.expect_value(t, post.conv_id, fmt.tprint(home))
	testing.expect_value(t, post.content, "hello @alice")
	testing.expect_value(t, again.id, post.id)
	testing.expect_value(
		t,
		ts.s.convs.home.last_msg,
		proto.Msg_Id(strconv.parse_u64(post.id) or_else 0),
	)
	msg := strings.clone(post.id)
	defer delete(msg)

	// Changing the message: edit, react and pin (which a regular member can't
	// do in a channel), then read it back.
	message := at(&owned, "/api/v1/messages/%s", msg)
	reaction := at(&owned, "/api/v1/messages/%s/reactions/%%F0%%9F%%91%%8D", msg)
	r = gt_run(
		t,
		&ts,
		&h,
		token,
		{
			{"PATCH", message, `{"content": "edited"}`, 204},
			{"PUT", reaction, "", 204},
			{"PUT", at(&owned, "/api/v1/messages/%s/pin", msg), "", 403},
			{"PATCH", message, `{}`, 400},
			{"GET", at(&owned, "%s?around=%s&limit=1", home_messages, msg), "", 200},
		},
	)
	if r == nil {
		return
	}
	page: []Seen_Post
	if gt_json(t, r[4], &page) && testing.expect_value(t, len(page), 1) {
		testing.expect_value(t, page[0].content, "edited")
		testing.expect(t, page[0].edited_timestamp != "")
		testing.expect(t, len(page[0].reactions) == 1 && page[0].reactions[0].me)
	}

	// A DM, a post in it and a pin there, which either participant may do.
	r = gt_run(
		t,
		&ts,
		&h,
		token,
		{{"POST", "/api/v1/dms", at(&owned, "%s%d%s", `{"account": "`, alice.id, `"}`), 200}},
	)
	if r == nil {
		return
	}
	dm: Seen_Conv
	if !gt_json(t, r[0], &dm) {
		return
	}
	dm_id := strings.clone(dm.id)
	defer delete(dm_id)
	testing.expect_value(t, dm.kind, "dm")
	testing.expect_value(t, dm.recipient, fmt.tprint(alice.id))
	dm_messages := at(&owned, "/api/v1/convs/%s/messages", dm_id)
	r = gt_run(t, &ts, &h, token, {{"POST", dm_messages, `{"content": "hi alice"}`, 201}})
	if r == nil {
		return
	}
	in_dm: Seen_Post
	gt_json(t, r[0], &in_dm)
	in_dm_id := strings.clone(in_dm.id)
	defer delete(in_dm_id)
	r = gt_run(
		t,
		&ts,
		&h,
		token,
		{
			{"PUT", at(&owned, "/api/v1/messages/%s/pin", in_dm_id), "", 204},
			{"GET", at(&owned, "/api/v1/convs/%s/pins", dm_id), "", 200},
			{
				"POST",
				at(&owned, "/api/v1/messages/%s/forward", msg),
				at(&owned, "%s%s%s", `{"conv": "`, dm_id, `"}`),
				201,
			},
			{"DELETE", reaction, "", 204},
			{"DELETE", message, "", 204},
			{"GET", at(&owned, "%s?around=%s&limit=1", home_messages, msg), "", 200},
		},
	)
	if r == nil {
		return
	}
	pins: []Seen_Post
	if gt_json(t, r[1], &pins) && testing.expect_value(t, len(pins), 1) {
		testing.expect_value(t, pins[0].id, in_dm_id)
	}
	copied: Seen_Post
	if gt_json(t, r[2], &copied) {
		testing.expect_value(t, copied.conv_id, dm_id)
		testing.expect_value(t, copied.content, "edited")
		testing.expect_value(t, copied.forwarded.author_id, fmt.tprint(bot))
	}
	if gt_json(t, r[5], &page) && testing.expect_value(t, len(page), 1) {
		testing.expect(t, page[0].deleted)
		testing.expect_value(t, len(page[0].reactions), 0)
	}

	// Reading: someone else posts and the bot reads everything.
	gt_post(t, &ts, admin, home, "something to read")
	gt_settle(&ts)
	r = gt_run(
		t,
		&ts,
		&h,
		token,
		{
			{"GET", at(&owned, "/api/v1/convs/%d", home), "", 200},
			{"POST", at(&owned, "/api/v1/convs/%d/read", home), "", 204},
			{"GET", at(&owned, "/api/v1/convs/%d", home), "", 200},
			{"POST", at(&owned, "/api/v1/convs/%d/typing", home), "", 204},
		},
	)
	if r == nil {
		return
	}
	before, after: Seen_Conv
	if gt_json(t, r[0], &before) && gt_json(t, r[2], &after) {
		testing.expect_value(t, before.unread, 1)
		testing.expect_value(t, after.unread, 0)
	}

	// Subscribing, the profile and the activity.
	subscription := at(&owned, "/api/v1/convs/%d/subscription", gaming)
	r = gt_run(
		t,
		&ts,
		&h,
		token,
		{
			{"PUT", subscription, "", 200},
			{"DELETE", subscription, "", 204},
			{"PATCH", "/api/v1/me", `{"display": "Helper Bot", "status": "testing"}`, 200},
			{"PATCH", "/api/v1/me", `{}`, 400},
			{"PUT", "/api/v1/me/activity", `{"activity": "busy"}`, 200},
			{"PUT", "/api/v1/me/activity", `{"activity": "sleepy"}`, 400},
		},
	)
	if r == nil {
		return
	}
	joined: Seen_Conv
	if gt_json(t, r[0], &joined) {
		testing.expect_value(t, joined.name, "Gaming")
		testing.expect(t, joined.member)
	}
	testing.expect(t, !conv_is_member(conv_by_id(&ts.s.convs, gaming), bot))
	me: Seen_Me
	if gt_json(t, r[2], &me) {
		testing.expect_value(t, me.display, "Helper Bot")
		testing.expect_value(t, me.status, "testing")
	}
	if gt_json(t, r[4], &me) {
		testing.expect_value(t, me.activity, "busy")
	}
}

// Ws is a bot's event socket for the tests. A thread of its own connects,
// upgrades the connection and stores everything it receives, while the test's
// thread keeps the server running.
@(private = "file")
Ws :: struct {
	port:       int,
	path:       string, // owned
	token:      string, // for the Authorization header, "" for none
	sock:       net.TCP_Socket,
	reader:     ^thread.Thread,
	mutex:      sync.Mutex,
	status:     int, // the response to the upgrade, once it has arrived
	frames:     [dynamic]string, // owned, the frames received so far
	close_code: int, // the close code the gateway sent, if any
	done:       bool,
}

@(private = "file")
ws_open :: proc(t: ^testing.T, ts: ^Test_Server, h: ^Harness, path: string, token := "") -> ^Ws {
	w := new(Ws)
	w.port, w.path, w.token = h.port, strings.clone(path), token
	w.reader = thread.create_and_start_with_poly_data(w, ws_run, init_context = context)
	start := time.tick_now()
	for ws_status(w) == 0 && time.tick_since(start) < 5 * time.Second {
		lt_turn(ts)
	}
	return w
}

@(private = "file")
ws_status :: proc(w: ^Ws) -> int {
	sync.guard(&w.mutex)
	return w.status
}

@(private = "file")
ws_run :: proc(w: ^Ws) {
	defer {
		sync.guard(&w.mutex)
		w.done = true
		if w.status == 0 {
			w.status = -1
		}
	}
	sock, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, w.port})
	if err != nil {
		return
	}
	w.sock = sock
	c := new(http.Conn)
	defer free(c)
	c.sock = sock
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"GET %s HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
		w.path,
	)
	strings.write_string(
		&b,
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
	)
	if w.token != "" {
		fmt.sbprintf(&b, "Authorization: Bot %s\r\n", w.token)
	}
	strings.write_string(&b, "\r\n")
	if !http.send_all(sock, transmute([]u8)strings.to_string(b)) {
		return
	}
	head, ok := http.read_head(c)
	if !ok {
		return
	}
	fields := strings.fields(
		strings.split_lines(head, context.temp_allocator)[0],
		context.temp_allocator,
	)
	status, _ := strconv.parse_int(fields[1])
	{
		sync.guard(&w.mutex)
		w.status = status
	}
	if status != 101 {
		return
	}
	payload := make([]u8, http.MAX_FRAME)
	defer delete(payload)
	for {
		op, n, frame_ok := http.read_frame(c, payload, from_server = true)
		if !frame_ok {
			return
		}
		#partial switch op {
		case .Text:
			sync.guard(&w.mutex)
			append(&w.frames, strings.clone(string(payload[:n])))
		case .Ping:
			http.write_frame(sock, .Pong, payload[:n], [4]u8{1, 2, 3, 4})
		case .Close:
			sync.guard(&w.mutex)
			if n >= 2 {
				w.close_code = int(payload[0]) << 8 | int(payload[1])
			}
			return
		}
	}
}

// ws_wait keeps the server (and `clients`) running until the socket has n
// frames or has closed. It returns whether the socket has n frames.
@(private = "file")
ws_wait :: proc(ts: ^Test_Server, w: ^Ws, n: int, clients: ..^lite.Client) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		{
			sync.guard(&w.mutex)
			if len(w.frames) >= n || w.done {
				return len(w.frames) >= n
			}
		}
		lt_turn(ts, ..clients)
	}
	return false
}

// ws_event parses frame i into `v` ({t, s, d}).
@(private = "file")
ws_event :: proc(t: ^testing.T, w: ^Ws, i: int, v: ^$T) -> bool {
	sync.guard(&w.mutex)
	if !testing.expectf(t, i >= 0 && i < len(w.frames), "no frame %d of %d", i, len(w.frames)) {
		return false
	}
	err := json.unmarshal(transmute([]u8)w.frames[i], v, allocator = context.temp_allocator)
	return testing.expectf(t, err == nil, "%v in %s", err, w.frames[i])
}

// ws_find returns the index of the first frame of kind `t`, starting at frame
// `from`. If `account` is given, the frame must also contain it. It returns -1
// if there is no such frame.
@(private = "file")
ws_find :: proc(t: ^testing.T, w: ^Ws, kind: string, from := 1, account := "") -> int {
	sync.guard(&w.mutex)
	for f, i in w.frames[min(from, len(w.frames)):] {
		e: Event_Other
		if json.unmarshal(transmute([]u8)f, &e, allocator = context.temp_allocator) != nil ||
		   e.t != kind {
			continue
		}
		if account == "" || e.d.account_id == account {
			return from + i
		}
	}
	testing.expectf(t, false, "no %s %s", kind, account)
	return -1
}

// ws_wait_for keeps everything running until the socket has a frame of kind
// `t` (about `account`, if that is given).
@(private = "file")
ws_wait_for :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	w: ^Ws,
	kind: string,
	account: string,
	clients: ..^lite.Client,
) {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		{
			sync.guard(&w.mutex)
			for f in w.frames {
				e: Event_Other
				json.unmarshal(transmute([]u8)f, &e, allocator = context.temp_allocator)
				if e.t == kind && (account == "" || e.d.account_id == account) {
					return
				}
			}
			if w.done {
				break
			}
		}
		lt_turn(ts, ..clients)
	}
	testing.expectf(t, false, "no %s came", kind)
}

// ws_kind returns the kind of frame i (its t).
@(private = "file")
ws_kind :: proc(t: ^testing.T, w: ^Ws, i: int) -> string {
	e: struct {
		t: string,
	}
	ws_event(t, w, i, &e)
	return e.t
}

// ws_close sends a close frame if the socket is still open and waits for the
// gateway to close the connection.
@(private = "file")
ws_close :: proc(ts: ^Test_Server, w: ^Ws) {
	if !w.done {
		bye := [2]u8{0x03, 0xe8} // 1000
		http.write_frame(w.sock, .Close, bye[:], [4]u8{9, 8, 7, 6})
	}
	start := time.tick_now()
	for !w.done && time.tick_since(start) < 5 * time.Second {
		lt_turn(ts)
	}
	net.close(w.sock)
	thread.join(w.reader)
	thread.destroy(w.reader)
	for f in w.frames {
		delete(f)
	}
	delete(w.frames)
	delete(w.path)
	free(w)
}

@(private = "file")
Event_Ready :: struct {
	t: string,
	s: int,
	d: struct {
		me:       Seen_Account,
		accounts: []Seen_Account,
		convs:    []Seen_Conv,
		online:   []string,
	},
}

@(private = "file")
Event_Message :: struct {
	t: string,
	s: int,
	d: Seen_Post,
}

@(private = "file")
Event_Reaction :: struct {
	t: string,
	s: int,
	d: struct {
		message_id: string,
		emoji:      string,
		count:      int,
		account:    Seen_Account,
	},
}

@(private = "file")
Event_Other :: struct {
	t: string,
	s: int,
	d: struct {
		id:         string,
		conv_id:    string,
		account_id: string,
		online:     bool,
		unread:     int,
		reason:     string,
		account:    Seen_Account,
	},
}

@(test)
test_gateway_events :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	bot := device_of(&ts.s.accounts, pub).account
	conv_member_add(&ts.s.convs, ts.s.convs.home, bot)
	home := ts.s.convs.home.id
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	// Without a token the socket is refused.
	nobody := ws_open(t, &ts, &h, "/api/v1/events")
	testing.expect_value(t, ws_status(nobody), 401)
	ws_close(&ts, nobody)

	// READY comes first and contains the whole model.
	w := ws_open(t, &ts, &h, "/api/v1/events", token)
	if !testing.expect_value(t, ws_status(w), 101) || !ws_wait(&ts, w, 1) {
		ws_close(&ts, w)
		return
	}
	ready: Event_Ready
	if ws_event(t, w, 0, &ready) {
		testing.expect_value(t, ready.t, "READY")
		testing.expect_value(t, ready.d.me.username, "helper")
		testing.expect_value(t, len(ready.d.accounts), 3)
		testing.expect(t, len(ready.d.convs) == 1 && ready.d.convs[0].home)
	}

	// Alice comes online and types, and the admin posts, reacts, edits and
	// deletes.
	server, _ := net.bound_endpoint(ts.s.sock)
	opt := lite.Options {
		server         = server,
		username       = "alice",
		login_password = "alice's password",
		name           = "alice",
	}
	ecdh.private_key_public_bytes(&ts.s.key, opt.server_key[:])
	alice_key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&alice_key, .X25519))
	alice_client: lite.Client
	testing.expect(t, lite.open(&alice_client, &alice_key, opt))
	defer lite.close(&alice_client)
	for _ in 0 ..< 5000 {
		if alice_client.phase == .Ready {
			break
		}
		lt_turn(&ts, &alice_client)
	}
	// She is online and typing.
	alice_id := fmt.aprint(alice.id)
	defer delete(alice_id)
	ws_wait_for(t, &ts, w, "PRESENCE_UPDATE", alice_id, &alice_client)
	typing_buf: [proto.TYPING_UP_SIZE]u8
	lite.send(&alice_client, proto.encode_typing_up(&typing_buf, home, 0))
	ws_wait_for(t, &ts, w, "TYPING_START", "", &alice_client)
	msg := gt_post(t, &ts, admin, home, "hello events")
	react_buf: [proto.MSG_REACT_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		&ts,
		admin,
		.Msg_React,
		proto.encode_msg_react(&react_buf, msg, "👍", true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	edit_buf: [proto.MSG_EDIT_MAX_SIZE]u8
	status, _ = ts_ask(t, &ts, admin, .Msg_Edit, proto.encode_msg_edit(&edit_buf, msg, "changed"))
	testing.expect_value(t, status, proto.Status.Ok)
	id_buf: [proto.MSG_ID_SIZE]u8
	status, _ = ts_ask(t, &ts, admin, .Msg_Delete, proto.encode_msg_id(&id_buf, msg))
	testing.expect_value(t, status, proto.Status.Ok)
	ws_wait_for(t, &ts, w, "MESSAGE_DELETE", "", &alice_client)

	// Every event is numbered, counting up from the number of READY.
	{
		sync.guard(&w.mutex)
		for f, i in w.frames {
			e: struct {
				s: int,
			}
			json.unmarshal(transmute([]u8)f, &e, allocator = context.temp_allocator)
			testing.expectf(t, e.s == ready.s + i, "frame %d is s %d, not %d", i, e.s, ready.s + i)
		}
	}
	presence: Event_Other
	if ws_event(t, w, ws_find(t, w, "PRESENCE_UPDATE", 1, alice_id), &presence) {
		testing.expect(t, presence.d.online)
	}
	typing: Event_Other
	if ws_event(t, w, ws_find(t, w, "TYPING_START"), &typing) {
		testing.expect_value(t, typing.d.conv_id, fmt.tprint(home))
		testing.expect_value(t, typing.d.account.username, "alice")
	}
	created: Event_Message
	if ws_event(t, w, ws_find(t, w, "MESSAGE_CREATE"), &created) {
		testing.expect_value(t, created.d.content, "hello events")
		testing.expect_value(t, created.d.author.username, "admin")
	}
	reacted: Event_Reaction
	if ws_event(t, w, ws_find(t, w, "MESSAGE_REACTION_ADD"), &reacted) {
		testing.expect_value(t, reacted.d.emoji, "👍")
		testing.expect_value(t, reacted.d.account.username, "admin")
		testing.expect_value(t, reacted.d.message_id, fmt.tprint(msg))
	}
	updated: Event_Message
	if ws_event(t, w, ws_find(t, w, "MESSAGE_UPDATE"), &updated) {
		testing.expect_value(t, updated.d.content, "changed")
	}
	deleted: Event_Other
	if ws_event(t, w, ws_find(t, w, "MESSAGE_DELETE"), &deleted) {
		testing.expect_value(t, deleted.d.id, fmt.tprint(msg))
	}
	testing.expect(
		t,
		ws_find(t, w, "MESSAGE_CREATE") < ws_find(t, w, "MESSAGE_REACTION_ADD") &&
		ws_find(t, w, "MESSAGE_REACTION_ADD") < ws_find(t, w, "MESSAGE_UPDATE") &&
		ws_find(t, w, "MESSAGE_UPDATE") < ws_find(t, w, "MESSAGE_DELETE"),
	)

	// The bot is also notified of its own actions, like reading a conversation.
	read := []Call{{method = "POST", path = "/api/v1/convs/1/read", token = token}}
	defer calls_destroy(read)
	gt_calls(t, &ts, &h, read)
	ws_wait_for(t, &ts, w, "READ_UPDATE", "")
	gt_settle(&ts)
	last: Event_Other
	{
		sync.guard(&w.mutex)
		json.unmarshal(
			transmute([]u8)w.frames[len(w.frames) - 1],
			&last,
			allocator = context.temp_allocator,
		)
	}
	ws_close(&ts, w)

	// After disconnecting and reconnecting, the bot receives what happened in
	// the meantime and nothing else.
	gt_post(t, &ts, admin, home, "while away")
	gt_settle(&ts)
	back := ws_open(t, &ts, &h, fmt.tprintf("/api/v1/events?resume=%d", last.s), token)
	if testing.expect_value(t, ws_status(back), 101) && ws_wait(&ts, back, 1) {
		away: Event_Message
		if ws_event(t, back, 0, &away) {
			testing.expect_value(t, away.t, "MESSAGE_CREATE")
			testing.expect_value(t, away.d.content, "while away")
			testing.expect_value(t, away.s, last.s + 1)
		}
	}

	// Resuming from too far back, or with the token in the URL, results in an
	// INVALID_SESSION followed by READY. The new socket takes over from the
	// previous one.
	again := ws_open(t, &ts, &h, fmt.tprintf("/api/v1/events?token=%s&resume=999999", token))
	if testing.expect_value(t, ws_status(again), 101) && ws_wait(&ts, again, 2) {
		testing.expect_value(t, ws_kind(t, again, 0), "INVALID_SESSION")
		testing.expect_value(t, ws_kind(t, again, 1), "READY")
	}
	ws_wait(&ts, back, 1000)
	testing.expect_value(t, back.close_code, 4000)
	ws_close(&ts, back)

	// After its token is revoked, the bot is notified and the socket is closed.
	revoke_buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Device_Revoke,
		proto.encode_device_revoke(revoke_buf[:], pub),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	ws_wait(&ts, again, 1000)
	{
		sync.guard(&again.mutex)
		n := len(again.frames)
		testing.expect(t, n >= 3)
		if n >= 3 {
			e: Event_Other
			json.unmarshal(
				transmute([]u8)again.frames[n - 1],
				&e,
				allocator = context.temp_allocator,
			)
			testing.expect_value(t, e.t, "LOGGED_OUT")
			testing.expect_value(t, e.d.reason, "revoked")
		}
	}
	testing.expect_value(t, again.close_code, 4001)
	ws_close(&ts, again)
}

@(test)
test_gateway_files :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	s := &ts.s
	dir := test_dir(t)
	dir = strings.clone(dir)
	defer delete(dir)
	defer remove_tree(dir)
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	attachments_open(s, {max_megabytes = 8, rate_kb = 1024 * 1024})
	defer attachments_close(s)
	admin := gt_admin(t, &ts)
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	bot := device_of(&ts.s.accounts, pub).account
	conv_member_add(&ts.s.convs, ts.s.convs.home, bot)
	home := ts.s.convs.home.id
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	// A file that is three windows long so that it has to be streamed, and a
	// picture.
	file := make([]u8, 3 * proto.FILE_WINDOW * proto.FILE_CHUNK_DATA + 77)
	defer delete(file)
	for &b, i in file {
		b = u8(i * 31) ~ u8(i >> 10)
	}
	jpeg := strings.clone(string(test_jpeg(64, 48, 9)))
	defer delete(jpeg)
	home_messages := fmt.aprintf("/api/v1/convs/%d/messages", home)
	defer delete(home_messages)

	calls := []Call {
		{
			method = "POST",
			path = "/api/v1/uploads?name=report%202026.bin",
			token = token,
			body = string(file),
		},
		{method = "POST", path = "/api/v1/uploads", token = token, body = "no name"},
		{method = "PUT", path = "/api/v1/me/avatar", token = token, body = jpeg},
		{method = "PUT", path = "/api/v1/me/avatar", token = token, body = "not a picture"},
		{method = "GET", path = "/api/v1/attachments/12345", token = token},
	}
	defer calls_destroy(calls)
	if !gt_calls(t, &ts, &h, calls) {
		return
	}
	testing.expectf(t, calls[0].status == 201, "upload: %d %s", calls[0].status, calls[0].reply)
	testing.expect_value(t, calls[1].status, 400)
	testing.expectf(t, calls[2].status == 200, "avatar: %d %s", calls[2].status, calls[2].reply)
	testing.expect_value(t, calls[3].status, 400)
	testing.expect_value(t, calls[4].status, 404)
	upload: struct {
		id:   string,
		name: string,
		size: int,
	}
	if !gt_json(t, calls[0].reply, &upload) {
		return
	}
	testing.expect_value(t, upload.name, "report 2026.bin")
	testing.expect_value(t, upload.size, len(file))
	me: struct {
		avatar: string,
	}
	gt_json(t, calls[2].reply, &me)
	testing.expect(t, me.avatar != "")
	post_body := strings.concatenate({`{"attachments": ["`, upload.id, `"]}`})
	defer delete(post_body)
	avatar_path := fmt.aprintf("/api/v1/blobs/%s", me.avatar)
	defer delete(avatar_path)

	// Posted with a message: the file is fetched back whole as the server
	// stores it, and so is the picture.
	posting := []Call {
		{method = "POST", path = home_messages, token = token, body = post_body},
		{method = "GET", path = avatar_path, token = token},
		{method = "DELETE", path = "/api/v1/me/avatar", token = token},
	}
	defer calls_destroy(posting)
	if !gt_calls(t, &ts, &h, posting) {
		return
	}
	testing.expectf(
		t,
		posting[0].status == 201,
		"post: %d %s",
		posting[0].status,
		posting[0].reply,
	)
	post: struct {
		content:     string,
		attachments: []struct {
			id:   string,
			name: string,
			size: int,
		},
	}
	if !gt_json(t, posting[0].reply, &post) || !testing.expect_value(t, len(post.attachments), 1) {
		return
	}
	testing.expect_value(t, post.content, "")
	testing.expect_value(t, post.attachments[0].name, "report 2026.bin")
	testing.expect_value(t, post.attachments[0].size, len(file))
	testing.expect_value(t, posting[1].status, 200)
	testing.expect_value(t, posting[1].type, "image/jpeg")
	testing.expect(t, posting[1].reply == jpeg)
	testing.expect_value(t, posting[2].status, 200)
	gt_json(t, posting[2].reply, &me)
	testing.expect_value(t, me.avatar, "")

	attachment := fmt.aprintf("/api/v1/attachments/%s", post.attachments[0].id)
	defer delete(attachment)
	fetching := []Call{{method = "GET", path = attachment, token = token}}
	defer calls_destroy(fetching)
	if gt_calls(t, &ts, &h, fetching) {
		testing.expect_value(t, fetching[0].status, 200)
		testing.expect_value(t, len(fetching[0].reply), len(file))
		testing.expect(t, fetching[0].reply == string(file), "the file came back different")
	}
}

@(test)
test_gateway_login_rule :: proc(t: ^testing.T) {
	at :: proc(address: string) -> net.Endpoint {
		ep, _ := net.parse_endpoint(address)
		return ep
	}
	// Without a proxy, logging in is only allowed from this machine.
	testing.expect(t, gateway.login_allowed(false, nil, at("127.0.0.1:5000"), ""))
	testing.expect(t, gateway.login_allowed(false, nil, at("[::1]:5000"), ""))
	testing.expect(t, !gateway.login_allowed(false, nil, at("10.0.0.7:5000"), ""))
	// Without a proxy, a forwarded protocol that the client claims is not
	// trusted.
	testing.expect(t, !gateway.login_allowed(false, nil, at("10.0.0.7:5000"), "https"))
	// Behind a proxy, the protocol that the proxy reports is trusted if the
	// request comes from where a proxy may be: this machine or a private
	// network.
	testing.expect(t, gateway.login_allowed(true, nil, at("10.0.0.7:5000"), "https"))
	testing.expect(t, gateway.login_allowed(true, nil, at("172.18.0.1:5000"), "https"))
	testing.expect(t, gateway.login_allowed(true, nil, at("192.168.1.2:5000"), "https"))
	testing.expect(t, gateway.login_allowed(true, nil, at("[fd00::2]:5000"), "https"))
	testing.expect(t, gateway.login_allowed(true, nil, at("127.0.0.1:5000"), "HTTPS"))
	testing.expect(t, !gateway.login_allowed(true, nil, at("127.0.0.1:5000"), ""))
	testing.expect(t, !gateway.login_allowed(true, nil, at("127.0.0.1:5000"), "http"))
	// Not from anywhere else: the port may be reachable around the proxy.
	testing.expect(t, !gateway.login_allowed(true, nil, at("203.0.113.5:5000"), "https"))
	testing.expect(t, !gateway.login_allowed(true, nil, at("172.32.0.1:5000"), "https"))
	testing.expect(t, !gateway.login_allowed(true, nil, at("[2001:db8::1]:5000"), "https"))
	// With the proxy's address given, only that is believed.
	proxy := at("203.0.113.5:443").address
	testing.expect(t, gateway.login_allowed(true, proxy, at("203.0.113.5:5000"), "https"))
	testing.expect(t, !gateway.login_allowed(true, proxy, at("10.0.0.7:5000"), "https"))
}

@(test)
test_gateway_limits :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	ts_account(t, &ts, "alice", "alice's password")
	one, _ := gt_token(t, &ts, admin, "one")
	defer delete(one)
	two, _ := gt_token(t, &ts, admin, "two")
	defer delete(two)

	// Each token has its own rate limit bucket: two requests at once, then one
	// every two seconds.
	{
		h: Harness
		gt_open(t, &ts, &h, settings = {rate = 0.5, burst = 2})
		defer gt_close(&ts, &h)
		calls := []Call {
			{method = "GET", path = "/api/v1/me", token = one},
			{method = "GET", path = "/api/v1/me", token = one},
			{method = "GET", path = "/api/v1/me", token = one},
			{method = "GET", path = "/api/v1/me", token = two},
		}
		defer calls_destroy(calls)
		if gt_calls(t, &ts, &h, calls) {
			testing.expect_value(t, calls[0].status, 200)
			testing.expect_value(t, calls[1].status, 200)
			testing.expect_value(t, calls[2].status, 429)
			testing.expect_value(t, error_of(calls[2].reply), "rate_limited")
			testing.expect(t, calls[2].retry >= 1 && calls[2].retry <= 2)
			testing.expect_value(t, calls[3].status, 200)
		}
	}

	// The connection limit allows as many connections as configured and no
	// more.
	{
		h: Harness
		gt_open(t, &ts, &h, settings = {max_connections = 1})
		defer gt_close(&ts, &h)
		calls := []Call {
			{method = "GET", path = "/api/v1/me", token = one},
			{method = "GET", path = "/api/v1/me", token = two},
			{method = "GET", path = "/api/v1/me", token = one},
		}
		defer calls_destroy(calls)
		if gt_calls(t, &ts, &h, calls) {
			testing.expect_value(t, calls[0].status, 200)
			testing.expect_value(t, calls[1].status, 503)
			testing.expect_value(t, calls[2].status, 200)
		}
	}

	// Behind a proxy, a password is only accepted if the proxy reports HTTPS.
	{
		h: Harness
		gt_open(t, &ts, &h, settings = {behind_proxy = true})
		defer gt_close(&ts, &h)
		LOGIN :: `{"username": "alice", "password": "alice's password"}`
		calls := []Call {
			{method = "POST", path = "/api/v1/login", body = LOGIN},
			{
				method = "POST",
				path = "/api/v1/login",
				body = LOGIN,
				header = "X-Forwarded-Proto: http\r\n",
			},
			{
				method = "POST",
				path = "/api/v1/login",
				body = LOGIN,
				header = "X-Forwarded-Proto: https\r\n",
			},
		}
		defer calls_destroy(calls)
		if gt_calls(t, &ts, &h, calls) {
			testing.expect_value(t, calls[0].status, 403)
			testing.expect_value(t, calls[1].status, 403)
			testing.expect_value(t, calls[2].status, 200)
		}
	}

	// Made-up tokens each have a bucket of their own, but each one makes the
	// gateway connect to the server, which one address may only make it do
	// so often. A token that is already connected isn't affected.
	{
		h: Harness
		gt_open(t, &ts, &h)
		defer gt_close(&ts, &h)
		calls: [gateway.OPENS_PER_ADDRESS + 2]Call
		calls[0] = {
			method = "GET",
			path   = "/api/v1/me",
			token  = one,
		}
		for &call in calls[1:len(calls) - 1] {
			made_up, _, made := proto.bot_token_make()
			testing.expect(t, made)
			call = {
				method = "GET",
				path   = "/api/v1/me",
				token  = made_up,
			}
		}
		calls[len(calls) - 1] = {
			method = "GET",
			path   = "/api/v1/me",
			token  = one,
		}
		defer for call in calls[1:len(calls) - 1] {
			delete(call.token)
		}
		defer calls_destroy(calls[:])
		if gt_calls(t, &ts, &h, calls[:]) {
			testing.expect_value(t, calls[0].status, 200)
			for call in calls[1:len(calls) - 2] {
				testing.expect(t, call.status != 429 && call.status != 200)
			}
			testing.expect_value(t, calls[len(calls) - 2].status, 429)
			testing.expect_value(t, calls[len(calls) - 1].status, 200)
		}
	}
}

@(test)
test_gateway_private_addresses :: proc(t: ^testing.T) {
	lan := net.IP4_Address{192, 168, 1, 20}
	testing.expect(t, gateway.address_private(lan))
	testing.expect(t, gateway.address_private(net.IP4_Address{10, 0, 0, 1}))
	testing.expect(t, !gateway.address_private(net.IP4_Address{8, 8, 8, 8}))
	// The same addresses as a dual-stack socket reports them.
	mapped := net.IP6_Address{0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0114} // ::ffff:192.168.1.20
	testing.expect(t, gateway.address_private(mapped))
	testing.expect(t, gateway.unmapped(mapped) == net.Address(lan))
	loop := net.IP6_Address{0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001} // ::ffff:127.0.0.1
	testing.expect(t, gateway.address_loopback(loop))
	public := net.IP6_Address{0, 0, 0, 0, 0, 0xffff, 0x0808, 0x0808}
	testing.expect(t, !gateway.address_private(public))
	testing.expect(t, gateway.address_private(net.IP6_Loopback))
}

// The moderation endpoints (gateway/moderation.odin), for a bot whose roles
// hold the permissions.
@(test)
test_gateway_moderation :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	admin := gt_admin(t, &ts)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	alice := logged_in(t, &ts, "alice")
	token, pub := gt_token(t, &ts, admin, "helper")
	defer delete(token)
	bot := account_by_id(&ts.s.accounts, device_of(&ts.s.accounts, pub).account)
	conv_member_add(&ts.s.convs, ts.s.convs.home, bot.id)
	home := ts.s.convs.home.id
	gaming := conv_by_name(&ts.s.convs, "Gaming").id
	join_buf: [4]u8
	status, _ := ts_ask(t, &ts, alice, .Voice_Join, proto.encode_room(&join_buf, proto.Room(home)))
	testing.expect_value(t, status, proto.Status.Ok)
	h: Harness
	gt_open(t, &ts, &h)
	defer gt_close(&ts, &h)

	owned := make([dynamic]string)
	defer {
		for p in owned {
			delete(p)
		}
		delete(owned)
	}
	at :: proc(owned: ^[dynamic]string, format: string, args: ..any) -> string {
		p := fmt.aprintf(format, ..args)
		append(owned, p)
		return p
	}
	mute := at(&owned, "/api/v1/accounts/%d/mute", alice_acc.id)
	voice := at(&owned, "/api/v1/accounts/%d/voice", alice_acc.id)
	ban := at(&owned, "/api/v1/accounts/%d/ban", alice_acc.id)
	ban_admin := at(&owned, "/api/v1/accounts/%d/ban", admin.account.id)
	// (A { in a format starts an argument index.)
	to_gaming := at(&owned, "%s%d%s", `{"conv": "`, gaming, `"}`)

	// Not without the permissions.
	gt_run(t, &ts, &h, token, {{"PUT", mute, "", 403}, {"PUT", ban, "", 403}})
	bot.perms += {.Move_Members, .Mute_Members, .Ban_Members}

	gt_run(t, &ts, &h, token, {{"PUT", mute, "", 204}})
	testing.expect(t, .Server_Muted in alice_acc.flags)
	gt_run(t, &ts, &h, token, {{"DELETE", mute, "", 204}})
	testing.expect(t, .Server_Muted not_in alice_acc.flags)

	gt_run(t, &ts, &h, token, {{"PUT", voice, "{}", 400}, {"PUT", voice, to_gaming, 204}})
	testing.expect_value(t, alice.room, proto.Room(gaming))
	gt_run(t, &ts, &h, token, {{"DELETE", voice, "", 204}})
	testing.expect_value(t, alice.room, proto.Room(0))

	r := gt_run(
	t,
	&ts,
	&h,
	token,
	{
		{"PUT", ban, `{"purge": "weekly"}`, 400},
		{"PUT", ban, `{"reason": "bye", "purge": "none"}`, 204},
		{"GET", "/api/v1/bans", "", 200},
		{"PUT", ban_admin, "", 400}, // never the owner
	},
	)
	testing.expect(t, .Disabled in alice_acc.flags)
	if r != nil {
		bans: []gateway.Ban_JSON
		if gt_json(t, r[2], &bans) && testing.expect_value(t, len(bans), 1) {
			testing.expect_value(t, bans[0].account.username, "alice")
			testing.expect_value(t, bans[0].by.username, "helper")
			testing.expect_value(t, bans[0].reason, "bye")
		}
	}
	gt_run(t, &ts, &h, token, {{"DELETE", ban, "", 204}})
	testing.expect(t, .Disabled not_in alice_acc.flags)

	// A ban that removes her messages tells the bot whose went.
	dir := test_dir(t)
	defer remove_tree(dir)
	testing.expect(t, blob_store_open(&ts.s.blobs, &ts.s.db, dir))
	// (The ban logged her out.)
	alice = logged_in(t, &ts, "alice")
	status, _ = post(t, &ts, alice, home, "something to regret", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	w := ws_open(t, &ts, &h, "/api/v1/events", token)
	defer ws_close(&ts, w)
	if !testing.expect_value(t, ws_status(w), 101) || !ws_wait(&ts, w, 1) {
		return
	}
	gt_run(t, &ts, &h, token, {{"PUT", ban, `{"reason": "bye", "purge": "all"}`, 204}})
	retention_drain(&ts.s.retention, &ts.s.blobs, &ts.s)
	ws_wait_for(t, &ts, w, "MESSAGES_PURGED", "")
	at_purge := ws_find(t, w, "MESSAGES_PURGED")
	purged: struct {
		d: gateway.Purged_JSON,
	}
	if at_purge > 0 && ws_event(t, w, at_purge, &purged) {
		alice_id := fmt.tprint(alice_acc.id)
		testing.expect_value(t, purged.d.author_id.? or_else "", alice_id)
		testing.expect_value(t, purged.d.before_id, "0")
		testing.expect_value(t, purged.d.conv_id, fmt.tprint(home))
	}
}
