package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"
import "core:time"

import "common:lite"
import "common:proto"

/*
Tests of the headless client (common/lite) against a real server: its
packet handling and the syncs that answer, on a loopback socket, turn
and turn about with the clients on this one thread. The accounts and
the admin who makes bots are the other tests' (ts_ procedures), which
need no socket.
*/

// What a client was told, through its handlers.
@(private = "file")
Heard :: struct {
	phases:  [dynamic]lite.Phase,
	events:  [dynamic]proto.Event_Op,
	answers: [dynamic]lite.Answer, // without their bodies
	states:  int,
	// Who the last snapshot said was here.
	here:    [dynamic]proto.Account_Id,
}

@(private = "file")
heard_destroy :: proc(h: ^Heard) {
	delete(h.phases)
	delete(h.events)
	delete(h.answers)
	delete(h.here)
}

@(private = "file")
HANDLERS :: lite.Handlers {
	phase = proc(c: ^lite.Client, phase: lite.Phase) {
		append(&(^Heard)(c.opt.user).phases, phase)
	},
	event = proc(c: ^lite.Client, op: proto.Event_Op, body: []u8) {
		append(&(^Heard)(c.opt.user).events, op)
	},
	state = proc(c: ^lite.Client, state: proto.Presence) {
		h := (^Heard)(c.opt.user)
		h.states += 1
		clear(&h.here)
		for u in state.users {
			append(&h.here, u.account)
		}
	},
}

@(private = "file")
answered :: proc(c: ^lite.Client, a: lite.Answer) {
	append(&(^Heard)(c.opt.user).answers, lite.Answer{op = a.op, status = a.status, tag = a.tag})
}

// lt_open is ts_open with the server's socket and key, for handshakes.
lt_open :: proc(t: ^testing.T, ts: ^Test_Server) {
	ts_open(t, ts)
	s := &ts.s
	s.max_sessions = 64
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	net.set_blocking(sock, false)
	s.sock = sock
}

// lt_close drops what sessions are left, then closes as ts_close does.
lt_close :: proc(ts: ^Test_Server) {
	s := &ts.s
	for len(s.sessions) > 0 {
		for idx in s.sessions {
			drop_session(s, idx)
			break
		}
	}
	delete(s.sessions)
	net.close(s.sock)
	ts_close(ts)
}

@(private = "file")
lt_options :: proc(ts: ^Test_Server, h: ^Heard) -> lite.Options {
	ep, _ := net.bound_endpoint(ts.s.sock)
	opt := lite.Options {
		server   = ep,
		name     = "test",
		handlers = HANDLERS,
		user     = h,
	}
	ecdh.private_key_public_bytes(&ts.s.key, opt.server_key[:])
	return opt
}

// lt_turn is a turn of each: the clients take in what has come and send
// what's due, and the server does as its loop does.
lt_turn :: proc(ts: ^Test_Server, clients: ..^lite.Client) {
	free_all(context.temp_allocator)
	now := time.tick_now()
	for c in clients {
		lite.receive(c)
		lite.step(c, now)
	}
	s := &ts.s
	buf: [proto.MAX_PACKET_SIZE]u8
	for {
		n, from, err := net.recv_udp(s.sock, buf[:])
		if err != nil || n == 0 {
			break
		}
		handle_packet(s, buf[:n], from)
	}
	auth_sync(s)
	stream_sync(s)
	sync_state(s)
	transfers_sync(s)
	attachments_sync(s)
	db_commit(&s.db)
	time.sleep(200 * time.Microsecond)
}

// lt_until takes turns until the client is in `phase`, or it's clear it
// won't be.
@(private = "file")
lt_until :: proc(t: ^testing.T, ts: ^Test_Server, c: ^lite.Client, phase: lite.Phase) -> bool {
	for _ in 0 ..< 5000 {
		if c.phase == phase {
			return true
		}
		lt_turn(ts, c)
	}
	testing.expectf(t, false, "never %v, still %v", phase, c.phase)
	return false
}

// lt_settle takes turns for a while, for what's on its way to arrive.
lt_settle :: proc(ts: ^Test_Server, clients: ..^lite.Client) {
	for _ in 0 ..< 100 {
		lt_turn(ts, ..clients)
	}
}

@(private = "file")
has_op :: proc(ops: []proto.Event_Op, op: proto.Event_Op) -> bool {
	for o in ops {
		if o == op {
			return true
		}
	}
	return false
}

// lt_bot makes a bot with the admin `admin`, and returns its token.
lt_bot :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	admin: ^Conn,
	username: string,
	key: ^ecdh.Private_Key,
) -> proto.Account_Id {
	testing.expect(t, ecdh.private_key_generate(key, .X25519))
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(key, pub[:])
	buf: [proto.BOT_BODY_MAX]u8
	status, body := ts_ask(
		t,
		ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], username, "", pub, ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _ := proto.decode_account_id(body)
	return id
}

@(test)
test_lite_token :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	key: ecdh.Private_Key
	id := lt_bot(t, &ts, admin, "helper", &key)
	testing.expect(t, conv_member_add(&ts.s.convs, ts.s.convs.home, id))

	h: Heard
	defer heard_destroy(&h)
	c: lite.Client
	testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
	defer lite.close(&c)
	testing.expect_value(t, c.phase, lite.Phase.Connecting)
	// No requests before there's a connection to send them on.
	testing.expect(t, !lite.request(&c, .Server_Info, nil, answered))

	// The token is all it takes: logged in by the handshake, then told
	// everything.
	if !lt_until(t, &ts, &c, .Ready) {
		return
	}
	testing.expect_value(t, len(h.phases), 2)
	testing.expect_value(t, h.phases[0], lite.Phase.Syncing)
	testing.expect_value(t, h.phases[1], lite.Phase.Ready)
	testing.expect(t, len(h.events) > 0 && h.events[0] == .Sync_Begin)
	testing.expect(t, has_op(h.events[:], .Self))
	testing.expect(t, has_op(h.events[:], .Conv_Changed))
	testing.expect_value(t, h.events[len(h.events) - 1], proto.Event_Op.Sync_End)
	u := conn_of(&ts.s, c.public_key)
	testing.expect(t, u != nil && u.account != nil && u.account.id == id)

	// Who is here comes once it's synced, and stops coming once acked.
	lt_settle(&ts, &c)
	testing.expect(t, h.states >= 1)
	found := false
	for a in h.here {
		found ||= a == id
	}
	testing.expect(t, found)
	if u != nil {
		testing.expect_value(t, u.acked_version, ts.s.version)
	}

	// It posts as anyone does, and hears of it as anyone does.
	clear(&h.events)
	buf: [proto.MAX_CHAT_SIZE + 64]u8
	body := proto.encode_msg_post(
		buf[:],
		{conv = ts.s.convs.home.id, nonce = 1, kind = .Text, text = "hello"},
	)
	testing.expect(t, lite.request(&c, .Msg_Post, body, answered, 7))
	lt_settle(&ts, &c)
	testing.expect_value(t, len(h.answers), 1)
	if len(h.answers) == 1 {
		testing.expect_value(t, h.answers[0].op, proto.Request_Op.Msg_Post)
		testing.expect_value(t, h.answers[0].status, proto.Status.Ok)
		testing.expect_value(t, h.answers[0].tag, 7)
	}
	testing.expect(t, has_op(h.events[:], .Msg_New))

	// Going says so: the server lets the connection go at once.
	pub := c.public_key
	lite.close(&c)
	lt_settle(&ts)
	testing.expect(t, conn_of(&ts.s, pub) == nil)
}

@(test)
test_lite_password :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))

	// A wrong password is the end of it.
	{
		h: Heard
		defer heard_destroy(&h)
		opt := lt_options(&ts, &h)
		opt.username, opt.login_password = "alice", "not alice's password"
		c: lite.Client
		testing.expect(t, lite.open(&c, &key, opt))
		defer lite.close(&c)
		lt_until(t, &ts, &c, .Failed)
		testing.expect_value(t, c.failure, lite.Failure.Login_Failed)
		testing.expect_value(t, c.login_status, proto.Status.Wrong_Password)
		testing.expect_value(t, len(h.phases), 2)
		testing.expect_value(t, h.phases[0], lite.Phase.Logging_In)
	}

	// The right one logs in, and makes the key a device of hers.
	{
		h: Heard
		defer heard_destroy(&h)
		opt := lt_options(&ts, &h)
		opt.username, opt.login_password = "alice", "alice's password"
		opt.device, opt.agent = "the gateway", "yap API"
		c: lite.Client
		testing.expect(t, lite.open(&c, &key, opt))
		defer lite.close(&c)
		lt_until(t, &ts, &c, .Ready)
		testing.expect_value(t, len(h.phases), 3)
		testing.expect_value(t, h.phases[0], lite.Phase.Logging_In)
		testing.expect_value(t, h.phases[1], lite.Phase.Syncing)
		d := device_of(&ts.s.accounts, c.public_key)
		testing.expect(t, d != nil)
		if d != nil {
			testing.expect_value(t, d.name, "the gateway")
		}
	}
	lt_settle(&ts)

	// From then on the key is enough.
	h: Heard
	defer heard_destroy(&h)
	c: lite.Client
	testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
	defer lite.close(&c)
	lt_until(t, &ts, &c, .Ready)
	testing.expect_value(t, h.phases[0], lite.Phase.Syncing)
	u := conn_of(&ts.s, c.public_key)
	testing.expect(t, u != nil && u.account == alice)
}

@(test)
test_lite_refused :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))

	// A key that's no device, and nothing to log in with.
	{
		h: Heard
		defer heard_destroy(&h)
		c: lite.Client
		testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
		defer lite.close(&c)
		lt_until(t, &ts, &c, .Failed)
		testing.expect_value(t, c.failure, lite.Failure.Not_Logged_In)
		// It said goodbye.
		lt_settle(&ts)
		testing.expect(t, conn_of(&ts.s, c.public_key) == nil)
	}

	// A server that isn't the one expected.
	{
		h: Heard
		defer heard_destroy(&h)
		opt := lt_options(&ts, &h)
		opt.server_key[0] ~= 1
		c: lite.Client
		testing.expect(t, lite.open(&c, &key, opt))
		defer lite.close(&c)
		lt_until(t, &ts, &c, .Failed)
		testing.expect_value(t, c.failure, lite.Failure.Wrong_Server_Key)
	}

	// A server with a password, without it.
	ts.s.password = "the server's password"
	defer ts.s.password = ""
	{
		h: Heard
		defer heard_destroy(&h)
		c: lite.Client
		testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
		defer lite.close(&c)
		lt_until(t, &ts, &c, .Failed)
		testing.expect_value(t, c.failure, lite.Failure.Refused)
		testing.expect_value(t, c.refusal, proto.Refusal.Wrong_Password)
	}
	// And with it.
	ts_account(t, &ts, "alice", "alice's password")
	h: Heard
	defer heard_destroy(&h)
	opt := lt_options(&ts, &h)
	opt.password = "the server's password"
	opt.username, opt.login_password = "alice", "alice's password"
	c: lite.Client
	testing.expect(t, lite.open(&c, &key, opt))
	defer lite.close(&c)
	lt_until(t, &ts, &c, .Ready)
}

@(test)
test_lite_restart :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	key: ecdh.Private_Key
	lt_bot(t, &ts, admin, "helper", &key)

	h: Heard
	defer heard_destroy(&h)
	c: lite.Client
	testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
	defer lite.close(&c)
	if !lt_until(t, &ts, &c, .Ready) {
		return
	}
	first := c.instance

	// Starting over: what was asked and not answered is lost with the
	// old connection, and the new one is told everything again.
	clear(&h.phases)
	clear(&h.events)
	testing.expect(t, lite.request(&c, .Server_Info, nil, answered))
	lite.restart(&c)
	testing.expect(t, !lite.request(&c, .Server_Info, nil, answered))
	testing.expect(t, !lite.ready(&c))
	lt_until(t, &ts, &c, .Ready)
	testing.expect(t, c.instance != first)
	testing.expect_value(t, len(h.answers), 1)
	if len(h.answers) == 1 {
		testing.expect_value(t, h.answers[0].status, proto.Status.Reset)
	}
	testing.expect_value(t, len(h.phases), 3)
	testing.expect_value(t, h.phases[0], lite.Phase.Connecting)
	testing.expect_value(t, h.phases[1], lite.Phase.Syncing)
	testing.expect(t, len(h.events) > 0 && h.events[0] == .Sync_Begin)

	// And asking works again.
	testing.expect(t, lite.request(&c, .Server_Info, nil, answered))
	lt_settle(&ts, &c)
	testing.expect_value(t, len(h.answers), 2)
	if len(h.answers) == 2 {
		testing.expect_value(t, h.answers[1].status, proto.Status.Ok)
	}
	testing.expect_value(t, len(ts.s.conns), 2) // the admin's, and this
}

@(test)
test_lite_logged_out :: proc(t: ^testing.T) {
	ts: Test_Server
	lt_open(t, &ts)
	defer lt_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	key: ecdh.Private_Key
	lt_bot(t, &ts, admin, "helper", &key)

	h: Heard
	defer heard_destroy(&h)
	c: lite.Client
	testing.expect(t, lite.open(&c, &key, lt_options(&ts, &h)))
	defer lite.close(&c)
	if !lt_until(t, &ts, &c, .Ready) {
		return
	}

	// The admin revokes its token: it's out, for good, and goes.
	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(t, &ts, admin, .Device_Revoke, proto.encode_device_revoke(buf[:], c.public_key))
	testing.expect_value(t, status, proto.Status.Ok)
	lt_until(t, &ts, &c, .Failed)
	testing.expect_value(t, c.failure, lite.Failure.Logged_Out)
	testing.expect_value(t, c.logout_reason, proto.Logout_Reason.Revoked)
	testing.expect(t, has_op(h.events[:], .Logged_Out))
	lt_settle(&ts)
	testing.expect(t, conn_of(&ts.s, c.public_key) == nil)
	// Nothing more is asked of a client that's failed.
	testing.expect(t, !lite.request(&c, .Server_Info, nil, answered))
}
