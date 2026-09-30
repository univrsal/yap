#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:testing"

@(private = "file")
Pair :: struct {
	client:     Session,
	server:     Session,
	client_key: ecdh.Private_Key,
	server_key: ecdh.Private_Key,
}

@(private = "file")
gen_key :: proc(t: ^testing.T, k: ^ecdh.Private_Key) {
	testing.expect(t, ecdh.private_key_generate(k, .X25519))
}

@(private = "file")
public_bytes :: proc(k: ^ecdh.Private_Key) -> (b: [KEY_SIZE]byte) {
	ecdh.private_key_public_bytes(k, b[:])
	return
}

@(private = "file")
handshake :: proc(t: ^testing.T, p: ^Pair, payload: []byte = nil) -> (received_payload: []byte) {
	gen_key(t, &p.server_key)
	gen_key(t, &p.client_key)

	ini: Initiator
	r: Responder
	defer initiator_reset(&ini)
	defer responder_reset(&r)

	init_packet, ok := initiator_start(&ini, &p.client_key)
	testing.expect(t, ok)
	testing.expect_value(t, len(init_packet), INIT_SIZE)

	resp: []byte
	resp, ok = responder_start(&r, &p.server_key, init_packet, 42)
	testing.expect(t, ok)
	// No amplification: the reply is never bigger than the request.
	testing.expect(t, len(resp) <= len(init_packet))

	server_key, result := initiator_read_resp(&ini, resp)
	testing.expect_value(t, result, Resp_Result.Ok)
	testing.expect_value(t, server_key, public_bytes(&p.server_key))

	finish: []byte
	finish, ok = initiator_finish(&ini, &p.client, payload)
	testing.expect(t, ok)
	testing.expect_value(t, receiver_index(finish), 42)

	received_payload, ok = responder_finish(&r, finish, &p.server)
	testing.expect(t, ok)

	testing.expect_value(t, p.client.remote_idx, 42)
	testing.expect_value(t, p.server.remote_idx, p.client.local_idx)
	testing.expect_value(t, p.server.peer_key, public_bytes(&p.client_key))
	testing.expect_value(t, p.client.peer_key, public_bytes(&p.server_key))
	return
}

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	p: Pair
	handshake(t, &p)

	pkt_buf, pt_buf: [MAX_PACKET_SIZE]byte
	msg := "hello"
	pkt, ok := seal(&p.client, transmute([]byte)msg, pkt_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, receiver_index(pkt), 42)

	pt: []byte
	pt, ok = open(&p.server, pkt, pt_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(pt), msg)

	// Keepalive (empty payload) in the other direction.
	pkt, ok = seal(&p.server, nil, pkt_buf[:])
	testing.expect(t, ok)
	pt, ok = open(&p.client, pkt, pt_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(pt), 0)
}

@(test)
test_finish_payload :: proc(t: ^testing.T) {
	// Where a server password will travel: encrypted, and only sent after
	// the client has checked the server's key.
	p: Pair
	secret := "hunter2"
	got := handshake(t, &p, transmute([]byte)secret)
	testing.expect_value(t, string(got), secret)
}

@(test)
test_reorder_loss_and_replay :: proc(t: ^testing.T) {
	p: Pair
	handshake(t, &p)

	bufs: [5][MAX_PACKET_SIZE]byte
	pkts: [5][]byte
	for i in 0 ..< 5 {
		ok: bool
		pkts[i], ok = seal(&p.client, []byte{byte(i)}, bufs[i][:])
		testing.expect(t, ok)
	}

	pt_buf: [MAX_PACKET_SIZE]byte
	// Out of order, with packet 2 lost entirely.
	for i in ([]int{0, 3, 1, 4}) {
		pt, ok := open(&p.server, pkts[i], pt_buf[:])
		testing.expect(t, ok)
		testing.expect_value(t, pt[0], byte(i))
	}
	// Replays are rejected.
	for i in ([]int{0, 3, 1, 4}) {
		_, ok := open(&p.server, pkts[i], pt_buf[:])
		testing.expect(t, !ok)
	}
	// A late but unseen packet within the window is still fine.
	_, ok := open(&p.server, pkts[2], pt_buf[:])
	testing.expect(t, ok)
}

@(test)
test_tampering_rejected :: proc(t: ^testing.T) {
	p: Pair
	handshake(t, &p)

	pkt_buf, pt_buf: [MAX_PACKET_SIZE]byte
	pkt, _ := seal(&p.client, []byte{1, 2, 3}, pkt_buf[:])

	// Flip a bit in the counter (header is AAD) and in the ciphertext.
	for off in ([]int{6, DATA_HEADER_SIZE}) {
		pkt[off] ~= 1
		_, ok := open(&p.server, pkt, pt_buf[:])
		testing.expect(t, !ok)
		pkt[off] ~= 1
	}
	// A rejected forgery must not have burned the real counter.
	_, ok := open(&p.server, pkt, pt_buf[:])
	testing.expect(t, ok)
}

@(test)
test_tampered_resp_resets_initiator :: proc(t: ^testing.T) {
	client_key, server_key: ecdh.Private_Key
	gen_key(t, &client_key)
	gen_key(t, &server_key)

	ini: Initiator
	r: Responder
	defer initiator_reset(&ini)
	defer responder_reset(&r)

	init_packet, _ := initiator_start(&ini, &client_key)
	resp, _ := responder_start(&r, &server_key, init_packet, 42)

	// Wrong receiver index: not for us, keep waiting.
	resp[5] ~= 1
	_, result := initiator_read_resp(&ini, resp)
	testing.expect_value(t, result, Resp_Result.Ignored)
	testing.expect_value(t, ini.state, Initiator_State.Sent_Init)
	resp[5] ~= 1

	// Corrupted encrypted server key: fail and start over.
	resp[RESP_HEADER_SIZE + KEY_SIZE + 3] ~= 1
	_, result = initiator_read_resp(&ini, resp)
	testing.expect_value(t, result, Resp_Result.Failed)
	testing.expect_value(t, ini.state, Initiator_State.Idle)
}

@(test)
test_bad_finish_rejected :: proc(t: ^testing.T) {
	client_key, server_key, other_key: ecdh.Private_Key
	gen_key(t, &client_key)
	gen_key(t, &server_key)
	gen_key(t, &other_key)

	// Two concurrent handshakes; one's Finish can't complete the other's.
	a, b: Initiator
	ra, rb: Responder
	defer {initiator_reset(&a); initiator_reset(&b); responder_reset(&ra); responder_reset(&rb)}

	init_a, _ := initiator_start(&a, &client_key)
	init_b, _ := initiator_start(&b, &other_key)
	resp_a, _ := responder_start(&ra, &server_key, init_a, 1)
	resp_b, _ := responder_start(&rb, &server_key, init_b, 2)
	_, _ = initiator_read_resp(&a, resp_a)
	_, _ = initiator_read_resp(&b, resp_b)

	sa, sb, out: Session
	finish_a, _ := initiator_finish(&a, &sa)
	_, _ = initiator_finish(&b, &sb)

	// Readdress a's Finish to b's handshake.
	finish_a[1] = 2
	_, ok := responder_finish(&rb, finish_a, &out)
	testing.expect(t, !ok)
}

@(test)
test_short_init_rejected :: proc(t: ^testing.T) {
	client_key, server_key: ecdh.Private_Key
	gen_key(t, &client_key)
	gen_key(t, &server_key)

	ini: Initiator
	r: Responder
	defer initiator_reset(&ini)
	defer responder_reset(&r)

	init_packet, _ := initiator_start(&ini, &client_key)
	_, ok := responder_start(&r, &server_key, init_packet[:INIT_SIZE - 1], 42)
	testing.expect(t, !ok)
}

@(test)
test_replay_window_edges :: proc(t: ^testing.T) {
	w: Replay_Window
	replay_update(&w, 100)
	testing.expect(t, replay_check(&w, 100 - REPLAY_WINDOW_SIZE + 1))
	testing.expect(t, !replay_check(&w, 100 - REPLAY_WINDOW_SIZE))
	replay_update(&w, 100 + 1000) // big jump clears the window
	testing.expect(t, replay_check(&w, 1099))
	testing.expect(t, !replay_check(&w, 1100))
	testing.expect(t, !replay_check(&w, 100))
}
