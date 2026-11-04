#+build !wasi
package conn

import "core:crypto/ecdh"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of the connection's own handshake (client.odin): that the server's key
// is trusted on first use and checked ever after, that nothing of ours (our
// hello, the server's password) is sent to a server whose key is wrong, what
// the user is told when the server refuses us, and giving up on a server that
// has gone quiet. Also the handshakes of the bulk and media links (bulk.odin,
// media.odin), which join the connection once it is up.
//
// The client talks to a server of the test's own on the loopback interface,
// whose end of the handshake the test plays with a proto.Responder.

@(private = "file")
Test_Handshake :: struct {
	tc:         Test_Conn,
	udp:        net.UDP_Socket, // the server's socket
	server_key: ecdh.Private_Key,
	server_pub: [proto.KEY_SIZE]u8,
	responder:  proto.Responder,
	session:    proto.Session, // the server's end, once the handshake is done
	path:       string, // the known servers file
}

@(private = "file")
th_open :: proc(t: ^testing.T, th: ^Test_Handshake, path: string, password := "") -> ^View {
	tc := &th.tc
	c := &tc.c
	tc_open(tc)
	// No session yet, and no connection (tc_open pretends there are).
	proto.link_reset(&c.link)
	c.has_instance = false

	err: net.Network_Error
	th.udp, err = net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, err == nil)
	ep, _ := net.bound_endpoint(th.udp)
	net.set_option(th.udp, .Receive_Timeout, 30 * time.Millisecond)
	testing.expect(t, ecdh.private_key_generate(&th.server_key, .X25519))
	ecdh.private_key_public_bytes(&th.server_key, th.server_pub[:])

	th.path = path
	os.remove(path)
	c.server_addr = strings.clone(fmt.tprintf("127.0.0.1:%d", ep.port))
	c.known_servers = strings.clone(path)
	c.password = strings.clone(password)
	c.conn_id = 0x1122334455667788
	testing.expect(t, ecdh.private_key_generate(&c.key, .X25519))
	ecdh.private_key_public_bytes(&c.key, c.my_key[:])
	testing.expect(t, transport_open(&c.transport, c.server_addr, 0))
	return tc_view(tc)
}

@(private = "file")
th_close :: proc(th: ^Test_Handshake) {
	c := &th.tc.c
	transport_close(&c.transport)
	proto.link_reset(&c.link)
	ecdh.private_key_clear(&c.key)
	delete(c.server_addr)
	delete(c.known_servers)
	delete(c.password)
	net.close(th.udp)
	ecdh.private_key_clear(&th.server_key)
	proto.responder_reset(&th.responder)
	proto.session_reset(&th.session)
	os.remove(th.path)
	tc_close(&th.tc)
}

// A packet the client has sent, and where from.
@(private = "file")
Received :: struct {
	packet: []u8, // temp allocator
	from:   net.Endpoint,
}

// th_received_from returns the packets the client has sent to the server since
// this was last called.
@(private = "file")
th_received_from :: proc(th: ^Test_Handshake) -> []Received {
	got := make([dynamic]Received, context.temp_allocator)
	buf: [proto.MAX_PACKET_SIZE]u8
	for {
		n, from, err := net.recv_udp(th.udp, buf[:])
		if err != nil || n == 0 {
			break
		}
		copied := make([]u8, n, context.temp_allocator)
		copy(copied, buf[:n])
		append(&got, Received{copied, from})
	}
	return got[:]
}

@(private = "file")
th_received :: proc(th: ^Test_Handshake) -> [][]u8 {
	got := th_received_from(th)
	packets := make([][]u8, len(got), context.temp_allocator)
	for r, i in got {
		packets[i] = r.packet
	}
	return packets
}

// th_resp has the client start a handshake, answers its Init, and hands it
// the answer. It returns what handle_server_packet did with it.
@(private = "file")
th_resp :: proc(t: ^testing.T, th: ^Test_Handshake) -> bool {
	c := &th.tc.c
	drive_handshake(c)
	sent := th_received(th)
	if !testing.expect_value(t, len(sent), 1) {
		return false
	}
	testing.expect_value(t, proto.packet_type(sent[0]), proto.Packet_Type.Handshake_Init)
	resp, ok := proto.responder_start(&th.responder, &th.server_key, sent[0], 4242)
	testing.expect(t, ok)
	return handle_server_packet(c, resp)
}

// th_finish reads the client's Finish and returns the hello in it.
@(private = "file")
th_finish :: proc(t: ^testing.T, th: ^Test_Handshake) -> (hello: []u8, ok: bool) {
	sent := th_received(th)
	if !testing.expect_value(t, len(sent), 1) {
		return
	}
	hello, ok = proto.responder_finish(&th.responder, sent[0], &th.session)
	testing.expect(t, ok, "the Finish could not be read")
	return
}

// th_send seals a message on the server's end and hands it to the client.
@(private = "file")
th_send :: proc(t: ^testing.T, th: ^Test_Handshake, pt: []u8) -> bool {
	buf: [proto.MAX_PACKET_SIZE]u8
	packet, ok := proto.seal(&th.session, pt, buf[:])
	testing.expect(t, ok)
	return handle_server_packet(&th.tc.c, packet)
}

@(test)
test_handshake_first_connection :: proc(t: ^testing.T) {
	th: Test_Handshake
	v := th_open(t, &th, "handshake_first.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c

	// The key is new, so it is trusted and saved, and the hello follows.
	testing.expect(t, th_resp(t, &th))
	testing.expect_value(t, c.server_key, th.server_pub)
	testing.expect_value(t, v.server_key, th.server_pub)
	trust, _ := check_server_key(th.path, c.server_addr, th.server_pub)
	testing.expect_value(t, trust, Trust.Known)

	hello, ok := th_finish(t, &th)
	if !ok {
		return
	}
	conn_id, password, link, hello_ok := proto.decode_hello(hello)
	testing.expect(t, hello_ok)
	testing.expect_value(t, conn_id, c.conn_id)
	testing.expect_value(t, password, "sesame")
	testing.expect_value(t, link, proto.Link.Main)

	// Until the Welcome, nothing else counts: the connection it belongs to is
	// not known yet.
	ping := [1]u8{u8(proto.Message_Kind.Stream)}
	testing.expect(t, th_send(t, &th, ping[:]))
	testing.expect(t, !c.has_current)
	testing.expect(t, !c.has_instance)

	welcome_buf: [proto.WELCOME_SIZE]u8
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 77, true)))
	testing.expect(t, c.has_current)
	testing.expect(t, c.has_instance)
	testing.expect_value(t, c.instance, u64(77))
	testing.expect_value(t, v.status, Status.Connected)
	testing.expect_value(t, c.auth.state, Login_State.Working)
	// A new connection starts its stream over, on both ends, with asking the
	// server about itself.
	proto.stream_reset(&th.tc.peer)
	sent := tc_sent(t, &th.tc)
	testing.expect(t, len(sent) > 0 && sent[0].op == .Server_Info)

	// The same Welcome again (as after a rekey) changes nothing; another one
	// is a new connection.
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 77, true)))
	testing.expect_value(t, len(tc_sent(t, &th.tc)), 0)
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 78, true)))
	testing.expect_value(t, c.instance, u64(78))
	proto.stream_reset(&th.tc.peer)
	sent = tc_sent(t, &th.tc)
	testing.expect(t, len(sent) > 0 && sent[0].op == .Server_Info)
}

// A server that shows a key other than the one saved for it may be someone
// else. It is not sent our hello, which carries the server's password.
@(test)
test_handshake_key_changed :: proc(t: ^testing.T) {
	th: Test_Handshake
	v := th_open(t, &th, "handshake_changed.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c
	context.logger = expected_errors() // the change is logged as an error

	saved: [proto.KEY_SIZE]u8
	saved[0] = 0xaa
	testing.expect(t, remember_server_key(th.path, c.server_addr, saved))

	testing.expect(t, !th_resp(t, &th))
	testing.expect_value(t, len(th_received(&th)), 0)
	testing.expect_value(t, c.handshake.state, proto.Initiator_State.Idle)
	testing.expect(t, !c.has_pending)
	testing.expect(t, !c.has_current)
	testing.expect_value(t, v.status, Status.Failed)
	testing.expect_value(
		t,
		v.error,
		fmt.tprintf("The key of %s has changed, so the connection was refused.", c.server_addr),
	)
	// The UI is shown both keys, so the user can choose to trust the new one.
	testing.expect(t, v.key_change.changed)
	testing.expect_value(t, v.key_change.server, c.server_addr)
	testing.expect_value(t, v.key_change.saved, saved)
	testing.expect_value(t, v.key_change.received, th.server_pub)
	// Nor is the key taken for the server's.
	testing.expect_value(t, c.server_key, [proto.KEY_SIZE]u8{})

	// The saved key is left as it was.
	trust, still := check_server_key(th.path, c.server_addr, th.server_pub)
	testing.expect_value(t, trust, Trust.Mismatch)
	testing.expect_value(t, still, saved)
}

// Saved keys that can't be read can't vouch for the server either.
@(test)
test_handshake_known_servers_unreadable :: proc(t: ^testing.T) {
	th: Test_Handshake
	v := th_open(t, &th, "handshake_unreadable.tmp")
	defer th_close(&th)
	c := &th.tc.c
	context.logger = expected_errors()
	testing.expect_value(t, os.make_directory(th.path), nil)

	testing.expect(t, !th_resp(t, &th))
	testing.expect_value(t, len(th_received(&th)), 0)
	testing.expect_value(t, v.status, Status.Failed)
	testing.expect(t, strings.contains(v.error, "could not be read"), v.error)
	testing.expect(t, !v.key_change.changed)
	testing.expect_value(t, c.server_key, [proto.KEY_SIZE]u8{})
}

@(test)
test_handshake_refused :: proc(t: ^testing.T) {
	th: Test_Handshake
	v := th_open(t, &th, "handshake_refused.tmp")
	defer th_close(&th)
	c := &th.tc.c

	testing.expect(t, th_resp(t, &th))
	_, ok := th_finish(t, &th)
	if !ok {
		return
	}
	refused_buf: [proto.REFUSED_SIZE]u8
	testing.expect(t, !th_send(t, &th, proto.encode_refused(&refused_buf, .Wrong_Password)))
	testing.expect(t, !c.has_current)
	testing.expect(t, !c.has_pending)
	testing.expect_value(t, v.status, Status.Failed)
	testing.expect_value(t, v.error, fmt.tprintf("%s requires a password.", c.server_addr))
}

@(test)
test_refusal_text :: proc(t: ^testing.T) {
	c: Server_Conn
	c.server_addr = "yap.example:7777"
	testing.expect_value(t, refusal_text(&c, .Wrong_Password), "yap.example:7777 requires a password.")
	c.password = "wrong"
	testing.expect_value(t, refusal_text(&c, .Wrong_Password), "The password for yap.example:7777 is wrong.")
	testing.expect_value(
		t,
		refusal_text(&c, .Version),
		"yap.example:7777 runs an incompatible version of yap.",
	)
	testing.expect_value(
		t,
		refusal_text(&c, .Already_Connected),
		"Another client is already connected to yap.example:7777 with this key. Close it and try again.",
	)
	testing.expect_value(t, refusal_text(&c, proto.Refusal(200)), "yap.example:7777 refused the connection.")
}

// A server that has said nothing for CONNECTION_LOST is given up on, and tried
// again every RECONNECT_EVERY.
@(test)
test_connection_lost :: proc(t: ^testing.T) {
	th: Test_Handshake
	v := th_open(t, &th, "handshake_lost.tmp")
	defer th_close(&th)
	c := &th.tc.c
	now := time.tick_now()

	// Quiet, but not for long enough.
	c.last_step = now
	c.last_recv = time.tick_add(now, -(CONNECTION_LOST - time.Second))
	check_alive(c)
	testing.expect(t, !c.lost)

	// Quiet because the computer was asleep: that's not the server's fault.
	c.last_step = time.tick_add(now, -(LOOP_STALLED + time.Second))
	c.last_recv = time.tick_add(now, -(CONNECTION_LOST + time.Minute))
	check_alive(c)
	testing.expect(t, !c.lost)

	// Never connected.
	c.last_recv = time.tick_add(time.tick_now(), -(CONNECTION_LOST + time.Second))
	check_alive(c)
	testing.expect(t, c.lost)
	testing.expect_value(t, v.status, Status.Failed)
	testing.expect_value(t, v.error, fmt.tprintf("Could not connect to %s.", c.server_addr))
	testing.expect(t, v.retrying)
	testing.expect(t, time.tick_diff(time.tick_now(), c.retry_at) > RECONNECT_EVERY - time.Second)

	// Until it is time to try again, no handshake is started.
	drive_handshake(c)
	testing.expect_value(t, len(th_received(&th)), 0)
	c.retry_at = time.tick_add(time.tick_now(), -time.Millisecond)
	drive_handshake(c)
	sent := th_received(&th)
	if testing.expect_value(t, len(sent), 1) {
		testing.expect_value(t, proto.packet_type(sent[0]), proto.Packet_Type.Handshake_Init)
	}
	testing.expect(t, time.tick_diff(time.tick_now(), c.retry_at) > RECONNECT_EVERY - time.Second)

	// Once it answers, the connection is back.
	resp, ok := proto.responder_start(&th.responder, &th.server_key, sent[0], 4242)
	testing.expect(t, ok)
	testing.expect(t, handle_server_packet(c, resp))
	_, ok = th_finish(t, &th)
	if !ok {
		return
	}
	welcome_buf: [proto.WELCOME_SIZE]u8
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 5, false)))
	testing.expect(t, !c.lost)
	testing.expect_value(t, v.status, Status.Connected)
	testing.expect_value(t, c.auth.state, Login_State.Needed)

	// Lost after having been connected says so.
	c.last_step = time.tick_now()
	c.last_recv = time.tick_add(c.last_step, -(CONNECTION_LOST + time.Second))
	check_alive(c)
	testing.expect(t, c.lost)
	testing.expect(t, !c.has_current)
	testing.expect_value(t, v.error, fmt.tprintf("Lost the connection to %s.", c.server_addr))
}

// ---- the bulk and media links ----

// th_connect takes the main link through its handshake up to the Welcome of
// connection `instance`.
@(private = "file")
th_connect :: proc(t: ^testing.T, th: ^Test_Handshake, instance: u64) -> bool {
	if !th_resp(t, th) {
		return false
	}
	if _, ok := th_finish(t, th); !ok {
		return false
	}
	buf: [proto.WELCOME_SIZE]u8
	testing.expect(t, th_send(t, th, proto.encode_welcome(&buf, instance, true)))
	c := &th.tc.c
	return testing.expect(t, c.has_instance && c.instance == instance)
}

// The server's end of a bulk or media link.
@(private = "file")
Side :: struct {
	responder: proto.Responder,
	session:   proto.Session,
	from:      net.Endpoint, // the link's socket
}

@(private = "file")
side_destroy :: proc(sd: ^Side) {
	proto.responder_reset(&sd.responder)
	proto.session_reset(&sd.session)
}

// side_send sends a packet to the link's socket and has the client read what
// arrives there (`receive`) until `done` holds. It returns whether it came to.
@(private = "file")
side_send :: proc(
	th: ^Test_Handshake,
	sd: ^Side,
	packet: []u8,
	receive: proc(c: ^Server_Conn),
	done: proc(c: ^Server_Conn) -> bool,
) -> bool {
	net.send_udp(th.udp, packet, sd.from)
	for _ in 0 ..< 500 {
		receive(&th.tc.c)
		if done(&th.tc.c) {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

// side_init returns the Init that the link has sent, and remembers where it
// came from.
@(private = "file")
side_init :: proc(t: ^testing.T, th: ^Test_Handshake, sd: ^Side) -> (init: []u8, ok: bool) {
	got := th_received_from(th)
	if !testing.expect_value(t, len(got), 1) {
		return
	}
	sd.from = got[0].from
	testing.expect_value(t, proto.packet_type(got[0].packet), proto.Packet_Type.Handshake_Init)
	return got[0].packet, true
}

// side_answer answers the link's Init with the server's key `key` and returns
// the hello of the Finish that follows.
@(private = "file")
side_answer :: proc(
	t: ^testing.T,
	th: ^Test_Handshake,
	sd: ^Side,
	receive: proc(c: ^Server_Conn),
	pending: proc(c: ^Server_Conn) -> bool,
) -> (
	hello: []u8,
	ok: bool,
) {
	init := side_init(t, th, sd) or_return
	resp, resp_ok := proto.responder_start(&sd.responder, &th.server_key, init, 5151)
	testing.expect(t, resp_ok)
	if !testing.expect(t, side_send(th, sd, resp, receive, pending), "no Finish") {
		return
	}
	got := th_received_from(th)
	if !testing.expect_value(t, len(got), 1) {
		return
	}
	testing.expect_value(t, got[0].from, sd.from)
	proto.session_reset(&sd.session)
	hello, ok = proto.responder_finish(&sd.responder, got[0].packet, &sd.session)
	testing.expect(t, ok, "the Finish could not be read")
	return
}

// side_seal seals a message on the server's end of the link.
@(private = "file")
side_seal :: proc(sd: ^Side, pt: []u8) -> []u8 {
	buf := make([]u8, proto.MAX_PACKET_SIZE, context.temp_allocator)
	packet, _ := proto.seal(&sd.session, pt, buf)
	return packet
}

@(private = "file")
bulk_pending :: proc(c: ^Server_Conn) -> bool {
	return c.bulk.has_pending
}

@(private = "file")
bulk_up :: proc(c: ^Server_Conn) -> bool {
	return c.bulk.has_current
}

@(private = "file")
bulk_held :: proc(c: ^Server_Conn) -> bool {
	return c.bulk.retry_at != {}
}

@(test)
test_bulk_link :: proc(t: ^testing.T) {
	th: Test_Handshake
	_ = th_open(t, &th, "bulk_link.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c
	defer bulk_close(c)
	sd: Side
	defer side_destroy(&sd)

	// Not before the main link has been welcomed.
	bulk_step(c)
	testing.expect(t, !c.bulk.transport.open)
	if !th_connect(t, &th, 77) {
		return
	}

	// Its own handshake, with a hello that names the same connection.
	bulk_step(c)
	hello, ok := side_answer(t, &th, &sd, bulk_receive, bulk_pending)
	if !ok {
		return
	}
	conn_id, password, link, hello_ok := proto.decode_hello(hello)
	testing.expect(t, hello_ok)
	testing.expect_value(t, conn_id, c.conn_id)
	testing.expect_value(t, password, "sesame")
	testing.expect_value(t, link, proto.Link.Bulk)
	welcome_buf: [proto.WELCOME_SIZE]u8
	welcome := side_seal(&sd, proto.encode_welcome(&welcome_buf, 77, false))
	if !testing.expect(t, side_send(&th, &sd, welcome, bulk_receive, bulk_up), "the bulk link isn't up") {
		return
	}
	testing.expect_value(t, c.bulk.retry_at, time.Tick{})

	// Heavy messages go over it, everything else over the main link.
	heavy := [?]u8{u8(proto.Message_Kind.Blob_Chunk), 1, 2, 3}
	light := [?]u8{u8(proto.Message_Kind.Typing), 1}
	testing.expect(t, send_data(c, heavy[:]))
	testing.expect(t, send_data(c, light[:]))
	got := th_received_from(&th)
	if testing.expect_value(t, len(got), 2) {
		out: [proto.MAX_PACKET_SIZE]u8
		for r in got {
			on_bulk := r.from == sd.from
			pt, opened := proto.open(&sd.session if on_bulk else &th.session, r.packet, out[:])
			testing.expect(t, opened && len(pt) > 0)
			if opened && len(pt) > 0 {
				want := proto.Message_Kind.Blob_Chunk if on_bulk else proto.Message_Kind.Typing
				testing.expect_value(t, proto.Message_Kind(pt[0]), want)
			}
		}
	}

	// It pings the server, so that it notices when the server stops answering.
	c.bulk.last_ping = {}
	bulk_step(c)
	got = th_received_from(&th)
	if testing.expect_value(t, len(got), 1) {
		testing.expect_value(t, got[0].from, sd.from)
		out: [proto.MAX_PACKET_SIZE]u8
		pt, opened := proto.open(&sd.session, got[0].packet, out[:])
		testing.expect(t, opened && len(pt) > 0 && proto.Message_Kind(pt[0]) == .Ping)
	}

	// A new connection drops it, and its handshake starts over on the same
	// socket.
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 78, true)))
	testing.expect(t, !c.bulk.has_current)
	testing.expect(t, c.bulk.transport.open)
	bulk_step(c)
	_, ok = side_init(t, &th, &sd)
	testing.expect(t, ok)
}

@(test)
test_bulk_link_refused :: proc(t: ^testing.T) {
	th: Test_Handshake
	_ = th_open(t, &th, "bulk_refused.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c
	defer bulk_close(c)
	sd: Side
	defer side_destroy(&sd)
	context.logger = expected_errors()
	if !th_connect(t, &th, 77) {
		return
	}

	// Another server than the one the main link reached: it isn't sent our
	// hello (which has the password in it), and is tried again later.
	other: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&other, .X25519))
	defer ecdh.private_key_clear(&other)
	bulk_step(c)
	init, ok := side_init(t, &th, &sd)
	if !ok {
		return
	}
	resp, _ := proto.responder_start(&sd.responder, &other, init, 5151)
	testing.expect(t, side_send(&th, &sd, resp, bulk_receive, bulk_held))
	testing.expect_value(t, len(th_received(&th)), 0)
	testing.expect(t, !c.bulk.has_pending)
	// Until then, nothing is sent.
	bulk_step(c)
	testing.expect_value(t, len(th_received(&th)), 0)

	// Refused (as when the main link isn't ready yet), and welcomed for
	// another connection than the main link's: tried again later either way.
	refused_buf: [proto.REFUSED_SIZE]u8
	welcome_buf: [proto.WELCOME_SIZE]u8
	answers := [][]u8 {
		proto.encode_refused(&refused_buf, .No_Connection),
		proto.encode_welcome(&welcome_buf, 99, false),
	}
	for answer in answers {
		c.bulk.retry_at = {}
		bulk_step(c)
		if _, answered := side_answer(t, &th, &sd, bulk_receive, bulk_pending); !answered {
			return
		}
		testing.expect(t, side_send(&th, &sd, side_seal(&sd, answer), bulk_receive, bulk_held))
		testing.expect(t, !c.bulk.has_current)
		testing.expect(t, !c.bulk.has_pending)
	}
}

@(private = "file")
media_pending :: proc(c: ^Server_Conn) -> bool {
	return c.media.has_pending
}

@(private = "file")
media_up :: proc(c: ^Server_Conn) -> bool {
	return c.media.has_current
}

@(private = "file")
media_held :: proc(c: ^Server_Conn) -> bool {
	return c.media.retry_at != {}
}

// media_start starts the media link's handshake as media_step does, which only
// does so with a video library to share or watch with.
@(private = "file")
media_start :: proc(t: ^testing.T, c: ^Server_Conn) {
	m := &c.media
	if !m.transport.open {
		testing.expect(t, transport_open(&m.transport, c.server_addr, 0, bulk = true, media = true))
	}
	s := proto.link_step(&m.link, &c.key, time.tick_now())
	testing.expect(t, s.started)
	transport_send(&m.transport, s.packet)
}

@(test)
test_media_link :: proc(t: ^testing.T) {
	th: Test_Handshake
	_ = th_open(t, &th, "media_link.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c
	defer media_close(c)
	sd: Side
	defer side_destroy(&sd)
	context.logger = expected_errors()
	if !th_connect(t, &th, 77) {
		return
	}

	media_start(t, c)
	hello, ok := side_answer(t, &th, &sd, media_receive, media_pending)
	if !ok {
		return
	}
	conn_id, password, link, _ := proto.decode_hello(hello)
	testing.expect_value(t, conn_id, c.conn_id)
	testing.expect_value(t, password, "sesame")
	testing.expect_value(t, link, proto.Link.Media)

	// Refused a couple of times: it counts them, to give up on the link
	// eventually.
	refused_buf: [proto.REFUSED_SIZE]u8
	refused := proto.encode_refused(&refused_buf, .Wrong_Password)
	testing.expect(t, side_send(&th, &sd, side_seal(&sd, refused), media_receive, media_held))
	testing.expect_value(t, c.media.refusals, 1)
	testing.expect(t, !c.media.has_pending)
	c.media.retry_at = {}
	media_start(t, c)
	if _, ok = side_answer(t, &th, &sd, media_receive, media_pending); !ok {
		return
	}
	testing.expect(t, side_send(&th, &sd, side_seal(&sd, refused), media_receive, media_held))
	testing.expect_value(t, c.media.refusals, 2)

	// Welcomed for another connection: tried again, but not as a refusal.
	welcome_buf: [proto.WELCOME_SIZE]u8
	c.media.retry_at = {}
	media_start(t, c)
	if _, ok = side_answer(t, &th, &sd, media_receive, media_pending); !ok {
		return
	}
	other := side_seal(&sd, proto.encode_welcome(&welcome_buf, 99, false))
	testing.expect(t, side_send(&th, &sd, other, media_receive, media_held))
	testing.expect(t, !c.media.has_current)
	testing.expect_value(t, c.media.refusals, 2)

	// Once it is up, the counts start over.
	c.media.retry_at = {}
	c.media.timeouts = 2
	media_start(t, c)
	if _, ok = side_answer(t, &th, &sd, media_receive, media_pending); !ok {
		return
	}
	welcome := side_seal(&sd, proto.encode_welcome(&welcome_buf, 77, false))
	if !testing.expect(t, side_send(&th, &sd, welcome, media_receive, media_up), "the media link isn't up") {
		return
	}
	testing.expect_value(t, c.media.refusals, 0)
	testing.expect_value(t, c.media.timeouts, 0)
	testing.expect_value(t, c.media.retry_at, time.Tick{})

	// A new connection drops it.
	c.media.refusals = 3
	testing.expect(t, th_send(t, &th, proto.encode_welcome(&welcome_buf, 78, true)))
	testing.expect(t, !c.media.has_current)
	testing.expect_value(t, c.media.refusals, 0)
}

// Like the bulk link, the media link only finishes its handshake with the
// server the main link reached.
@(test)
test_media_link_other_server :: proc(t: ^testing.T) {
	th: Test_Handshake
	_ = th_open(t, &th, "media_other.tmp", password = "sesame")
	defer th_close(&th)
	c := &th.tc.c
	defer media_close(c)
	sd: Side
	defer side_destroy(&sd)
	context.logger = expected_errors()
	if !th_connect(t, &th, 77) {
		return
	}

	other: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&other, .X25519))
	defer ecdh.private_key_clear(&other)
	media_start(t, c)
	init, ok := side_init(t, &th, &sd)
	if !ok {
		return
	}
	resp, _ := proto.responder_start(&sd.responder, &other, init, 5151)
	testing.expect(t, side_send(&th, &sd, resp, media_receive, media_held))
	testing.expect_value(t, len(th_received(&th)), 0)
	testing.expect(t, !c.media.has_pending)
	testing.expect_value(t, c.media.refusals, 0)
}
