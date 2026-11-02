#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:testing"
import "core:time"

// The whole life of an Initiator_Link, played against a Responder: the
// handshake, the first packet that promotes the new session, data in both
// directions, rekeying while packets from the old session are still in
// flight, and what a link refuses.

@(private = "file")
Peers :: struct {
	client_key: ecdh.Private_Key,
	server_key: ecdh.Private_Key,
	link:       Initiator_Link,
	server:     Session, // the server's end of the link's newest session
	next_idx:   Session_Id,
}

@(private = "file")
peers_open :: proc(t: ^testing.T, p: ^Peers) {
	testing.expect(t, ecdh.private_key_generate(&p.client_key, .X25519))
	testing.expect(t, ecdh.private_key_generate(&p.server_key, .X25519))
	p.next_idx = 1000
}

@(private = "file")
peers_close :: proc(p: ^Peers) {
	link_reset(&p.link)
	session_reset(&p.server)
	ecdh.private_key_clear(&p.client_key)
	ecdh.private_key_clear(&p.server_key)
}

// handshake runs one handshake through the link as far as its pending session,
// and returns the packet from the server that confirms it (a keepalive).
@(private = "file")
handshake :: proc(
	t: ^testing.T,
	p: ^Peers,
	hello: []u8,
	restart := false,
) -> (
	confirm: []u8,
	server: Session,
) {
	step := link_step(&p.link, &p.client_key, time.tick_now(), restart = restart)
	testing.expect(t, step.started)
	testing.expect_value(t, packet_type(step.packet), Packet_Type.Handshake_Init)

	r: Responder
	defer responder_reset(&r)
	p.next_idx += 1
	resp, ok := responder_start(&r, &p.server_key, step.packet, p.next_idx)
	testing.expect(t, ok)

	// The link accepts the Resp and shows whose key it is, to be checked
	// before the hello is sent.
	server_key: [KEY_SIZE]byte
	server_key, ok = link_resp(&p.link, resp)
	testing.expect(t, ok)
	want: [KEY_SIZE]byte
	ecdh.private_key_public_bytes(&p.server_key, want[:])
	testing.expect_value(t, server_key, want)

	finish: []u8
	finish, ok = link_finish(&p.link, hello)
	testing.expect(t, ok)
	testing.expect(t, p.link.has_pending)
	payload: []u8
	payload, ok = responder_finish(&r, finish, &server)
	testing.expect(t, ok)
	testing.expect_value(t, string(payload), string(hello))

	buf := make([]u8, MAX_PACKET_SIZE, context.temp_allocator)
	confirm, ok = seal(&server, nil, buf)
	testing.expect(t, ok)
	return
}

@(test)
test_link_handshake_and_data :: proc(t: ^testing.T) {
	p: Peers
	peers_open(t, &p)
	defer peers_close(&p)

	hello := []u8{1, 2, 3, 4}
	confirm, server := handshake(t, &p, hello)
	defer session_reset(&server)
	testing.expect(t, !p.link.has_current, "the session was used before the server confirmed it")

	// The server's first packet is opened with the pending session, which says
	// so; the link switches over when the caller is sure of the packet.
	out: [MAX_PACKET_SIZE]u8
	pt, pending, ok := link_open(&p.link, confirm, out[:])
	testing.expect(t, ok)
	testing.expect(t, pending)
	testing.expect_value(t, len(pt), 0)
	first := link_promote(&p.link)
	testing.expect(t, first, "the first session was not reported as the first")
	testing.expect(t, p.link.has_current && !p.link.has_pending && !p.link.has_previous)
	testing.expect_value(t, p.link.handshake.state, Initiator_State.Idle)

	// Data both ways.
	buf: [MAX_PACKET_SIZE]u8
	msg := "hello from the server"
	pkt, sealed := seal(&server, transmute([]u8)msg, buf[:])
	testing.expect(t, sealed)
	pt, pending, ok = link_open(&p.link, pkt, out[:])
	testing.expect(t, ok)
	testing.expect(t, !pending)
	testing.expect_value(t, string(pt), msg)

	reply := "and back"
	pkt, sealed = seal(&p.link.current, transmute([]u8)reply, buf[:])
	testing.expect(t, sealed)
	back, back_ok := open(&server, pkt, out[:])
	testing.expect(t, back_ok)
	testing.expect_value(t, string(back), reply)

	// Hearing from the server is noted, which keeps the link from rekeying.
	testing.expect(t, p.link.last_recv != {})

	// A packet is not opened twice.
	_, _, ok = link_open(&p.link, pkt, out[:])
	testing.expect(t, !ok)
}

@(test)
test_link_rekey_keeps_old_packets :: proc(t: ^testing.T) {
	p: Peers
	peers_open(t, &p)
	defer peers_close(&p)
	out: [MAX_PACKET_SIZE]u8
	buf: [MAX_PACKET_SIZE]u8

	confirm, first_server := handshake(t, &p, []u8{1})
	defer session_reset(&first_server)
	_, _, ok := link_open(&p.link, confirm, out[:])
	testing.expect(t, ok)
	testing.expect(t, link_promote(&p.link))
	first_idx := p.link.current.local_idx

	// A packet the server sent on the first session, which arrives late.
	late, sealed := seal(&first_server, transmute([]u8)string("late"), buf[:])
	testing.expect(t, sealed)
	late_copy := make([]u8, len(late), context.temp_allocator)
	copy(late_copy, late)

	// The link rekeys while the first session is still good.
	confirm2, second_server := handshake(t, &p, []u8{2}, restart = true)
	defer session_reset(&second_server)
	testing.expect_value(t, p.link.current.local_idx, first_idx) // still sending on the old one
	pt, pending, open_ok := link_open(&p.link, confirm2, out[:])
	testing.expect(t, open_ok && pending && len(pt) == 0)
	testing.expect(t, !link_promote(&p.link), "a rekey was reported as a first session")
	testing.expect(t, p.link.current.local_idx != first_idx)
	testing.expect(t, p.link.has_previous)
	testing.expect_value(t, p.link.previous.local_idx, first_idx)

	// The late packet still opens, with the old session.
	pt, pending, ok = link_open(&p.link, late_copy, out[:])
	testing.expect(t, ok)
	testing.expect(t, !pending)
	testing.expect_value(t, string(pt), "late")

	// New data comes over the new session.
	pkt, sealed2 := seal(&second_server, transmute([]u8)string("new"), buf[:])
	testing.expect(t, sealed2)
	pt, pending, ok = link_open(&p.link, pkt, out[:])
	testing.expect(t, ok && !pending)
	testing.expect_value(t, string(pt), "new")

	// A third session drops the first for good.
	confirm3, third_server := handshake(t, &p, []u8{3}, restart = true)
	defer session_reset(&third_server)
	_, _, ok = link_open(&p.link, confirm3, out[:])
	testing.expect(t, ok)
	testing.expect(t, !link_promote(&p.link))
	pkt, sealed = seal(&first_server, transmute([]u8)string("too late"), buf[:])
	testing.expect(t, sealed)
	_, _, ok = link_open(&p.link, pkt, out[:])
	testing.expect(t, !ok, "a packet of a session two rekeys old was accepted")
}

@(test)
test_link_refuses :: proc(t: ^testing.T) {
	p: Peers
	peers_open(t, &p)
	defer peers_close(&p)
	out: [MAX_PACKET_SIZE]u8

	// Nothing to finish before a Resp, and nothing to open before a session.
	_, ok := link_finish(&p.link, []u8{1})
	testing.expect(t, !ok)
	junk: [DATA_HEADER_SIZE + TAG_SIZE + 4]u8
	junk[0] = u8(Packet_Type.Data)
	_, _, ok = link_open(&p.link, junk[:], out[:])
	testing.expect(t, !ok)

	// A Resp that isn't an answer to our Init.
	step := link_step(&p.link, &p.client_key, time.tick_now())
	testing.expect(t, step.started)
	resp: [RESP_SIZE]u8
	resp[0] = u8(Packet_Type.Handshake_Resp)
	_, ok = link_resp(&p.link, resp[:])
	testing.expect(t, !ok)
	_, ok = link_resp(&p.link, nil)
	testing.expect(t, !ok)

	// A Resp from the server that was altered.
	r: Responder
	defer responder_reset(&r)
	good, resp_ok := responder_start(&r, &p.server_key, step.packet, 77)
	testing.expect(t, resp_ok)
	bad := make([]u8, len(good), context.temp_allocator)
	copy(bad, good)
	bad[len(bad) - 1] ~= 1
	_, ok = link_resp(&p.link, bad)
	testing.expect(t, !ok)
	// It is no use now: the handshake was dropped when the Resp failed.
	_, ok = link_finish(&p.link, []u8{1})
	testing.expect(t, !ok)
	testing.expect(t, !p.link.has_pending)

	// A cookie that isn't one.
	_, ok = link_cookie(&p.link, junk[:])
	testing.expect(t, !ok)
	_, ok = link_cookie(&p.link, nil)
	testing.expect(t, !ok)
}

@(test)
test_link_reset :: proc(t: ^testing.T) {
	p: Peers
	peers_open(t, &p)
	defer peers_close(&p)
	out: [MAX_PACKET_SIZE]u8

	confirm, server := handshake(t, &p, []u8{1})
	defer session_reset(&server)
	_, _, ok := link_open(&p.link, confirm, out[:])
	testing.expect(t, ok)
	testing.expect(t, link_promote(&p.link))
	buf: [MAX_PACKET_SIZE]u8
	pkt, sealed := seal(&server, transmute([]u8)string("x"), buf[:])
	testing.expect(t, sealed)

	link_reset(&p.link)
	testing.expect(t, !p.link.has_current && !p.link.has_pending && !p.link.has_previous)
	// The keys are wiped, not just forgotten.
	testing.expect_value(t, p.link.current.local_idx, Session_Id(0))
	testing.expect_value(t, p.link.current.send_n, u64(0))
	testing.expect_value(t, p.link.current.peer_key, [KEY_SIZE]byte{})
	testing.expect_value(t, p.link.handshake.state, Initiator_State.Idle)
	_, _, ok = link_open(&p.link, pkt, out[:])
	testing.expect(t, !ok, "a packet was opened after the link was reset")

	// A fresh handshake works after a reset.
	confirm2, server2 := handshake(t, &p, []u8{2})
	defer session_reset(&server2)
	_, pending, ok2 := link_open(&p.link, confirm2, out[:])
	testing.expect(t, ok2 && pending)
	testing.expect(t, link_promote(&p.link))
}

@(test)
test_link_abandon_drops_pending :: proc(t: ^testing.T) {
	p: Peers
	peers_open(t, &p)
	defer peers_close(&p)
	out: [MAX_PACKET_SIZE]u8

	confirm, server := handshake(t, &p, []u8{1})
	defer session_reset(&server)
	testing.expect(t, p.link.has_pending)
	link_abandon(&p.link)
	testing.expect(t, !p.link.has_pending)
	testing.expect_value(t, p.link.handshake.state, Initiator_State.Idle)
	// What the server sent on the abandoned session is not opened.
	_, _, ok := link_open(&p.link, confirm, out[:])
	testing.expect(t, !ok)
}
