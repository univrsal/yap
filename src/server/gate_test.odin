package server

import "core:crypto/ecdh"
import "core:net"
import "core:testing"
import "core:time"

import "common:proto"
import "gate"

// A busy server asks for a cookie, and a client that has it gets in. A
// forged Init with a wrong cookie gets nowhere, and the handshakes in
// progress are counted down as they finish or are dropped.
@(test)
test_handshake_gate :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 16
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	s.sock = sock
	defer net.close(sock)
	defer delete(s.sessions)

	client, client_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, client_err, nil)
	defer net.close(client)
	net.set_option(client, .Receive_Timeout, time.Second)
	from, _ := net.bound_endpoint(client)
	buf: [proto.MAX_PACKET_SIZE]u8

	// Up to gate.cookie_after(16) = 4 handshakes in progress, Inits are
	// answered right away.
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	waiting: [4]proto.Initiator
	defer for &ini in waiting {
		proto.initiator_reset(&ini)
	}
	for &ini in waiting {
		init, _ := proto.initiator_start(&ini, &key)
		handle_packet(s, init, from)
		n, _, recv_err := net.recv_udp(client, buf[:])
		testing.expect_value(t, recv_err, nil)
		testing.expect_value(t, proto.packet_type(buf[:n]), proto.Packet_Type.Handshake_Resp)
	}
	testing.expect_value(t, s.gate.half_open, 4)

	// The next one is asked for a cookie, and nothing is kept for it.
	ini: proto.Initiator
	defer proto.initiator_reset(&ini)
	init, _ := proto.initiator_start(&ini, &key)
	handle_packet(s, init, from)
	n, _, recv_err := net.recv_udp(client, buf[:])
	testing.expect_value(t, recv_err, nil)
	testing.expect_value(t, proto.packet_type(buf[:n]), proto.Packet_Type.Handshake_Cookie)
	testing.expect_value(t, len(s.sessions), 4)

	// The same cookie from another address isn't accepted.
	testing.expect(t, proto.initiator_read_cookie(&ini, buf[:n]))
	elsewhere := from
	elsewhere.port += 1
	handle_packet(s, proto.initiator_packet(&ini), elsewhere)
	testing.expect_value(t, len(s.sessions), 4)

	// From the right address, the Init with the cookie starts the handshake,
	// which then finishes as usual.
	handle_packet(s, proto.initiator_packet(&ini), from)
	testing.expect_value(t, len(s.sessions), 5)
	n, _, recv_err = net.recv_udp(client, buf[:])
	testing.expect_value(t, recv_err, nil)
	_, result := proto.initiator_read_resp(&ini, buf[:n])
	testing.expect_value(t, result, proto.Resp_Result.Ok)
	testing.expect_value(t, s.gate.half_open, 5)
	hello_buf: [proto.HELLO_MAX_SIZE]u8
	sess: proto.Session
	finish, _ := proto.initiator_finish(&ini, &sess, proto.encode_hello(&hello_buf, 1, ""))
	handle_packet(s, finish, from)
	n, _, recv_err = net.recv_udp(client, buf[:])
	testing.expect_value(t, recv_err, nil)
	out: [proto.MAX_PACKET_SIZE]u8
	pt, opened := proto.open(&sess, buf[:n], out[:])
	testing.expect(t, opened)
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Welcome)
	testing.expect_value(t, s.gate.half_open, 4)

	// Dropping the handshakes in progress counts them down to nothing.
	for len(s.sessions) > 0 {
		for idx in s.sessions {
			drop_session(s, idx)
			break
		}
	}
	testing.expect_value(t, s.gate.half_open, 0)
	testing.expect_value(t, len(s.gate.by_addr), 0)
}

// The limits on handshakes in progress: in total, and from one address.
@(test)
test_handshake_gate_limits :: proc(t: ^testing.T) {
	g: gate.Gate
	defer gate.destroy(&g)
	MAX :: 1024
	init: [proto.INIT_COOKIE_SIZE]u8
	init[0] = u8(proto.Packet_Type.Handshake_Init)
	remote := net.Endpoint{net.IP4_Address{192, 0, 2, 1}, 5000}
	local := net.Endpoint{net.IP4_Loopback, 5000}

	// One address may only have so many handshakes in progress, except
	// this machine.
	for _ in 0 ..< gate.HALF_OPEN_PER_ADDRESS {
		gate.opened(&g, remote)
		gate.opened(&g, local)
	}
	verdict, _ := gate.check(&g, init[:proto.INIT_SIZE], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Drop)
	verdict, _ = gate.check(&g, init[:proto.INIT_SIZE], local, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Accept)
	gate.closed(&g, remote)
	verdict, _ = gate.check(&g, init[:proto.INIT_SIZE], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Accept)

	// Over the threshold a cookie is needed. Up to half of the sessions,
	// an Init that has one is let in, beyond that not even then.
	g.half_open = gate.cookie_after(MAX)
	cookie: [proto.COOKIE_SIZE]u8
	verdict, cookie = gate.check(&g, init[:proto.INIT_SIZE], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Cookie)
	copy(init[proto.INIT_SIZE:], cookie[:])
	verdict, _ = gate.check(&g, init[:], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Accept)
	g.half_open = MAX / 2
	verdict, _ = gate.check(&g, init[:], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Drop)
	// A full session table turns everybody away.
	g.half_open = gate.cookie_after(MAX)
	verdict, _ = gate.check(&g, init[:], remote, MAX, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Drop)

	// A cookie made with the secret before the current one still works,
	// one older than that doesn't.
	g.rotated = time.tick_add(time.tick_now(), -gate.COOKIE_ROTATE)
	verdict, _ = gate.check(&g, init[:], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Accept)
	g.rotated = time.tick_add(time.tick_now(), -gate.COOKIE_ROTATE)
	verdict, _ = gate.check(&g, init[:], remote, 0, MAX)
	testing.expect_value(t, verdict, gate.Verdict.Cookie)
}

// An address that keeps getting the server password wrong is ignored for a
// while, and nobody else is.
@(test)
test_handshake_gate_password :: proc(t: ^testing.T) {
	g: gate.Gate
	defer gate.destroy(&g)
	init: [proto.INIT_SIZE]u8
	init[0] = u8(proto.Packet_Type.Handshake_Init)
	guesser := net.Endpoint{net.IP4_Address{192, 0, 2, 1}, 5000}
	other := net.Endpoint{net.IP4_Address{192, 0, 2, 2}, 5000}
	for _ in 0 ..< gate.PASSWORD_FAILURES - 1 {
		gate.wrong_password(&g, guesser)
	}
	verdict, _ := gate.check(&g, init[:], guesser, 0, 1024)
	testing.expect_value(t, verdict, gate.Verdict.Accept)
	gate.wrong_password(&g, guesser)
	verdict, _ = gate.check(&g, init[:], guesser, 0, 1024)
	testing.expect_value(t, verdict, gate.Verdict.Drop)
	// Another port of the same address doesn't help.
	guesser.port += 1
	verdict, _ = gate.check(&g, init[:], guesser, 0, 1024)
	testing.expect_value(t, verdict, gate.Verdict.Drop)
	verdict, _ = gate.check(&g, init[:], other, 0, 1024)
	testing.expect_value(t, verdict, gate.Verdict.Accept)
}

// A Handshake_Finish counts, and gets a session, for the address that its
// Init came from, the one that the Resp went to. Its own source is only a
// claim: with somebody else's address on it, wrong passwords would be counted
// against that address (and shut it out), and the session would send its
// answers there. Such a Finish is ignored, and the handshake is still there
// for the real one.
@(test)
test_finish_source :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.password = "the server password"
	s.max_sessions = 64
	testing.expect(t, ecdh.private_key_generate(&s.key, .X25519))
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, err, nil)
	s.sock = sock
	defer net.close(sock)
	defer delete(s.sessions)

	client, client_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect_value(t, client_err, nil)
	defer net.close(client)
	net.set_option(client, .Receive_Timeout, time.Second)
	from, _ := net.bound_endpoint(client)
	victim := net.Endpoint{net.IP4_Address{192, 0, 2, 9}, 4000}
	buf: [proto.MAX_PACKET_SIZE]u8
	hello_buf: [proto.HELLO_MAX_SIZE]u8

	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))

	// Many wrong passwords, with the victim's address as the source of the
	// Finish, each on its own handshake.
	for _ in 0 ..< gate.PASSWORD_FAILURES + 5 {
		ini: proto.Initiator
		init, _ := proto.initiator_start(&ini, &key)
		handle_packet(s, init, from)
		n, _, recv_err := net.recv_udp(client, buf[:])
		testing.expect_value(t, recv_err, nil)
		_, result := proto.initiator_read_resp(&ini, buf[:n])
		testing.expect_value(t, result, proto.Resp_Result.Ok)
		sess: proto.Session
		finish, _ := proto.initiator_finish(&ini, &sess, proto.encode_hello(&hello_buf, 1, "wrong"))
		handle_packet(s, finish, victim)
		// Nothing happened to the handshake: it is still waiting for its Finish.
		for _, c in s.sessions {
			testing.expect(t, !c.keyed)
		}
		proto.initiator_reset(&ini)
		for idx in s.sessions {
			drop_session(s, idx)
			break
		}
	}
	// The victim isn't shut out.
	init: [proto.INIT_SIZE]u8
	init[0] = u8(proto.Packet_Type.Handshake_Init)
	verdict, _ := gate.check(&s.gate, init[:], victim, 0, 1024)
	testing.expect_value(t, verdict, gate.Verdict.Accept)

	// From the address that took part, a wrong password still counts, and
	// is refused.
	ini: proto.Initiator
	defer proto.initiator_reset(&ini)
	init_packet, _ := proto.initiator_start(&ini, &key)
	handle_packet(s, init_packet, from)
	n, _, recv_err := net.recv_udp(client, buf[:])
	testing.expect_value(t, recv_err, nil)
	_, result := proto.initiator_read_resp(&ini, buf[:n])
	testing.expect_value(t, result, proto.Resp_Result.Ok)
	sess: proto.Session
	finish, _ := proto.initiator_finish(&ini, &sess, proto.encode_hello(&hello_buf, 1, "wrong"))
	handle_packet(s, finish, from)
	n, _, recv_err = net.recv_udp(client, buf[:])
	testing.expect_value(t, recv_err, nil)
	out: [proto.MAX_PACKET_SIZE]u8
	pt, opened := proto.open(&sess, buf[:n], out[:])
	testing.expect(t, opened)
	testing.expect_value(t, proto.Message_Kind(pt[0]), proto.Message_Kind.Refused)
	testing.expect_value(t, len(s.sessions), 0)
}

// Sessions that have finished their handshake but not logged in are limited
// per address and in all, so that a host can't fill the table with them. A
// logged in connection's sessions aren't counted.
@(test)
test_unlogged_room :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.max_sessions = 128
	defer delete(s.sessions)
	remote := net.Endpoint{net.IP4_Address{192, 0, 2, 1}, 5000}
	other := net.Endpoint{net.IP4_Address{192, 0, 2, 2}, 5000}
	local := net.Endpoint{net.IP4_Loopback, 5000}

	add :: proc(s: ^Server, from: net.Endpoint, conn: ^Conn = nil) -> ^Client {
		c := new(Client)
		c.keyed, c.endpoint, c.conn = true, from, conn
		for {
			idx := proto.random_index()
			if idx not_in s.sessions {
				s.sessions[idx] = c
				break
			}
		}
		return c
	}
	defer for _, c in s.sessions {
		free(c)
	}

	// An unfinished handshake isn't counted either.
	pending := add(s, remote)
	pending.keyed = false
	for _ in 0 ..< UNLOGGED_PER_ADDRESS - 1 {
		add(s, remote)
	}
	testing.expect(t, unlogged_room(s, remote))
	add(s, remote)
	testing.expect(t, !unlogged_room(s, remote))
	testing.expect(t, unlogged_room(s, other))
	testing.expect(t, unlogged_room(s, local)) // this machine is the relay's

	// The sessions of a connection that is logged in are no concern.
	account := new(Account)
	defer free(account)
	user := new(Conn)
	defer free(user)
	user.account = account
	for _ in 0 ..< 40 {
		add(s, remote, user)
	}
	testing.expect_value(t, len(s.sessions), 1 + UNLOGGED_PER_ADDRESS + 40)

	// All together at most half the table (64 of 128): 16 of them are from
	// `remote`, the rest from other addresses.
	for i in 0 ..< 47 {
		add(s, net.Endpoint{net.IP4_Address{198, 51, 100, u8(i)}, 5000})
	}
	testing.expect(t, unlogged_room(s, other)) // 16 + 47 = 63
	add(s, other)
	testing.expect(t, !unlogged_room(s, other)) // 64
	testing.expect(t, !unlogged_room(s, local)) // not even this machine
}
