package server

import "core:crypto/ecdh"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"

import "common:proto"

// The server tests' harness. A Test_Server is a Server without its socket.
// Connections are created by hand, requests are passed to rpc_handle as if
// they had come off a connection's stream, and whatever the server queues
// on that stream in return is read back the way a client would read it (the
// ts_ procedures).
//
// Passwords are hashed by the real hashing thread, using a parameter set that
// makes hashing fast.

// A connection's other end: the stream a client would have and what has
// been received from it.
Test_Client :: struct {
	stream:    proto.Stream,
	responses: map[u32]Test_Response,
	events:    [dynamic]Test_Event,
}

Test_Response :: struct {
	status: proto.Status,
	body:   []u8, // temp allocator
}

Test_Event :: struct {
	op:   proto.Event_Op,
	body: []u8, // temp allocator
}

Test_Server :: struct {
	s:        Server,
	clients:  map[^Conn]^Test_Client,
	requests: u32,
	keys:     u8,
}

TEST_CHANNELS := []string{"Lobby", "Gaming"}

ts_open :: proc(t: ^testing.T, ts: ^Test_Server, db_path := DB_MEMORY) {
	s := &ts.s
	s.version = 1
	s.auth.params = HASH_PARAMS_TEST
	s.requests_unlimited = true // test_request_limit turns it on
	testing.expect(t, db_open(&s.db, db_path))
	testing.expect(t, accounts_load(&s.accounts, &s.db))
	testing.expect(t, convs_load(&s.convs, &s.db, TEST_CHANNELS, &s.accounts))
	testing.expect(t, hash_worker_start(&s.hasher))
}

ts_close :: proc(ts: ^Test_Server) {
	s := &ts.s
	hash_worker_stop(&s.hasher)
	auth_destroy(&s.auth)
	for u, client in ts.clients {
		proto.stream_destroy(&client.stream)
		delete(client.responses)
		delete(client.events)
		free(client)
		proto.stream_destroy(&u.stream)
		drop_conn_transfers(u)
		free(u)
	}
	delete(ts.clients)
	// Free what verify_test.odin put in the email queues. There is no
	// email thread and no config of its own to free.
	for &m in s.email.inbox {
		mail_destroy(&m)
	}
	delete(s.email.inbox)
	delete(s.email.jobs)
	// Frees the push jobs that push_test.odin queued; no push thread is running in tests
	// either.
	push_close(&s.push)
	delete(s.conns)
	delete(s.waiting)
	calls_destroy(s)
	gate_destroy(&s.gate)
	convs_destroy(&s.convs)
	retention_close(&s.retention)
	blob_store_close(&s.blobs)
	files_destroy(s)
	accounts_destroy(&s.accounts)
	db_close(&s.db)
}

// ts_account creates an account directly in the store with a password
// that the test knows.
ts_account :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	username, password: string,
	flags: proto.Account_Flags = {},
) -> ^Account {
	p := password_of(password)
	secret, ok := secret_make(&p, HASH_PARAMS_TEST)
	testing.expect(t, ok)
	acc := account_add(&ts.s.accounts, username, username, secret, flags)
	testing.expect(t, acc != nil)
	testing.expect(t, conv_member_add(&ts.s.convs, ts.s.convs.home, acc.id))
	return acc
}

// ts_connect simulates a device connecting. It creates a new connection
// with `key`, or with a unique key if none is given. As in the real
// server, a device the server already knows is logged in immediately.
ts_connect :: proc(ts: ^Test_Server, key: [proto.KEY_SIZE]u8 = {}) -> ^Conn {
	s := &ts.s
	u := new(Conn)
	u.key = key
	if key == {} {
		ts.keys += 1
		u.key[0] = ts.keys
	}
	s.last_num += 1
	u.num = s.last_num
	u.instance = u64(u.num)
	stream_init(&u.stream)
	s.waiting[u.key] = u
	ts.clients[u] = new(Test_Client)
	auth_known_device(s, u)
	return u
}

// ts_disconnect simulates a connection going away, as happens when its
// last session ends.
ts_disconnect :: proc(ts: ^Test_Server, u: ^Conn) {
	conn_logout(&ts.s, u)
	delete_key(&ts.s.waiting, u.key)
}

// ts_pump moves everything the server has queued for a connection to
// its client end and sorts what arrives into responses and events.
ts_pump :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) {
	client := ts.clients[u]
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	now := time.tick_now()
	for {
		frame, ok := proto.stream_next_frame(&u.stream, now, proto.STREAM_RESEND, buf[:])
		if !ok {
			break
		}
		testing.expect_value(
			t,
			proto.stream_receive(&client.stream, frame),
			proto.Stream_Error.None,
		)
		ack_buf: [proto.STREAM_ACK_SIZE]u8
		if ack, due := proto.stream_ack(&client.stream, &ack_buf); due {
			proto.stream_acked(&u.stream, ack)
		}
	}
	for {
		msg, ok := proto.stream_next(&client.stream)
		if !ok {
			break
		}
		kind, known := proto.app_kind(msg)
		testing.expect(t, known)
		#partial switch kind {
		case .Response:
			id, status, body := proto.decode_response(msg)
			client.responses[id] = {status, temp_copy(body)}
		case .Event:
			op, body := proto.decode_event(msg)
			append(&client.events, Test_Event{op, temp_copy(body)})
		case:
			testing.fail(t)
		}
	}
}

temp_copy :: proc(data: []u8) -> []u8 {
	out := make([]u8, len(data), context.temp_allocator)
	copy(out, data)
	return out
}

// ts_ask sends a request as `u` and waits for the answer. For requests
// that involve a password, the answer comes from the hashing thread.
ts_ask :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	op: proto.Request_Op,
	body: []u8 = nil,
) -> (
	status: proto.Status,
	response: []u8,
) {
	ts.requests += 1
	id := ts.requests
	rpc_handle(&ts.s, u, proto.encode_request(id, op, body))
	client := ts.clients[u]
	for _ in 0 ..< 5000 {
		auth_sync(&ts.s)
		ts_pump(t, ts, u)
		if r, answered := client.responses[id]; answered {
			// No query may be left holding a read open, because that would
			// prevent checkpoints from finishing.
			testing.expectf(t, db_open_reads(&ts.s.db) == 0, "%v left a statement open", op)
			return r.status, r.body
		}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "no answer to a request")
}

ts_login :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	username, password: string,
	device := "test device",
) -> (
	status: proto.Status,
	flags: proto.Account_Flags,
) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		ts,
		u,
		.Auth_Login,
		proto.encode_auth_login(buf[:], username, password, device),
	)
	if status == .Ok {
		ok: bool
		_, flags, ok = proto.decode_auth_login_response(body)
		testing.expect(t, ok)
	}
	return
}

// ts_events returns the events sent to a connection since the last time
// it was called.
ts_events :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> []Test_Event {
	ts_pump(t, ts, u)
	client := ts.clients[u]
	out := make([]Test_Event, len(client.events), context.temp_allocator)
	copy(out, client.events[:])
	clear(&client.events)
	return out
}

has_event :: proc(events: []Test_Event, op: proto.Event_Op) -> (Test_Event, bool) {
	for e in events {
		if e.op == op {
			return e, true
		}
	}
	return {}, false
}

// logged_in returns a new connection that is logged in to an account with the
// password "a password". The events sent on logging in are consumed.
logged_in :: proc(t: ^testing.T, ts: ^Test_Server, username: string) -> ^Conn {
	u := ts_connect(ts)
	status, _ := ts_login(t, ts, u, username, "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, ts, u)
	return u
}

// test_dir returns a new folder for one test, which the test has to remove when
// it is over.
test_dir :: proc(t: ^testing.T) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	testing.expect(t, err == nil)
	return dir
}

file_in :: proc(dir, name: string) -> string {
	path, _ := os.join_path({dir, name}, context.temp_allocator)
	return path
}

// The requests on a message that tests make again and again, each returning
// the server's answer.

edit_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	text: string,
) -> proto.Status {
	buf := new([proto.MSG_EDIT_MAX_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Edit, proto.encode_msg_edit(buf, id, text))
	return status
}

delete_as :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id) -> proto.Status {
	buf := new([proto.MSG_ID_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Delete, proto.encode_msg_id(buf, id))
	return status
}

pin_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	on: bool,
) -> proto.Status {
	buf := new([proto.MSG_PIN_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Pin, proto.encode_msg_pin(buf, id, on))
	return status
}

react_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	emoji: string,
	on: bool,
) -> proto.Status {
	buf := new([proto.MSG_REACT_MAX_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_React, proto.encode_msg_react(buf, id, emoji, on))
	return status
}

// dm_open_as opens (or finds) the DM between `u` and `other`.
dm_open_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	other: proto.Account_Id,
) -> (
	status: proto.Status,
	conv: proto.Conv_Id,
) {
	buf: [4]u8
	body: []u8
	status, body = ts_ask(t, ts, u, .DM_Open, proto.encode_account_id(&buf, other))
	if status == .Ok {
		ok: bool
		conv, ok = proto.decode_conv_id(body)
		testing.expect(t, ok)
	}
	return
}

// Test_Link is a client's end of a link, for the tests that do real
// handshakes over loopback UDP sockets (bulk_test, media_test).
Test_Link :: struct {
	sock: net.UDP_Socket,
	from: net.Endpoint,
	sess: proto.Session,
}

link_open_socket :: proc(t: ^testing.T, l: ^Test_Link) {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	net.set_option(sock, .Receive_Timeout, time.Second)
	l.sock = sock
	l.from, _ = net.bound_endpoint(sock)
}

// link_recv reads the next Data packet on the link and decrypts it.
link_recv :: proc(t: ^testing.T, l: ^Test_Link, out: []u8) -> []u8 {
	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	if !testing.expect_value(t, err, nil) {
		return nil
	}
	pt, ok := proto.open(&l.sess, buf[:n], out)
	testing.expect(t, ok)
	return pt
}

// link_handshake_with runs the client side of a handshake on `l`. `handle`
// gets each packet with `data`, as the server's packet handling would off its
// socket. It returns the server's answer, which is either Welcome or Refused,
// after reading and discarding the other two of the three copies it sends.
link_handshake_with :: proc(
	t: ^testing.T,
	l: ^Test_Link,
	key: ^ecdh.Private_Key,
	conn_id: u64,
	link: proto.Link,
	out: []u8,
	handle: proc(data: rawptr, pkt: []u8, from: net.Endpoint),
	data: rawptr,
) -> []u8 {
	ini: proto.Initiator
	init, started := proto.initiator_start(&ini, key)
	testing.expect(t, started)
	handle(data, init, l.from)

	buf: [proto.MAX_PACKET_SIZE]u8
	n, _, err := net.recv_udp(l.sock, buf[:])
	testing.expect_value(t, err, nil)
	_, result := proto.initiator_read_resp(&ini, buf[:n])
	testing.expect_value(t, result, proto.Resp_Result.Ok)

	hello_buf: [proto.HELLO_MAX_SIZE]u8
	hello := proto.encode_hello(&hello_buf, conn_id, "", link)
	finish, finished := proto.initiator_finish(&ini, &l.sess, hello)
	testing.expect(t, finished)
	handle(data, finish, l.from)
	answer := link_recv(t, l, out)
	copy_buf: [proto.MAX_PAYLOAD_SIZE]u8
	for _ in 1 ..< 3 {
		link_recv(t, l, copy_buf[:])
	}
	return answer
}
