package proto

import "core:crypto/ecdh"
import "core:testing"

@(private = "file")
Pair :: struct {
	client:     Session,
	server:     Session,
	client_key: ecdh.Private_Key,
}

@(private = "file")
gen_key :: proc(t: ^testing.T, k: ^ecdh.Private_Key) {
	testing.expect(t, ecdh.private_key_generate(k, .X25519))
}

@(private = "file")
handshake :: proc(t: ^testing.T, p: ^Pair) {
	server_key: ecdh.Private_Key
	gen_key(t, &server_key)
	gen_key(t, &p.client_key)
	server_pub: ecdh.Public_Key
	ecdh.public_key_set_priv(&server_pub, &server_key)

	ini: Initiator
	init_packet, ok := initiator_start(&ini, &p.client_key, &server_pub)
	testing.expect(t, ok)

	resp_buf: [MAX_PACKET_SIZE]byte
	resp: []byte
	resp, ok = responder_accept(&server_key, init_packet, 42, &p.server, resp_buf[:])
	testing.expect(t, ok)

	testing.expect(t, initiator_finish(&ini, resp, &p.client))
	testing.expect_value(t, p.client.remote_idx, 42)
	testing.expect_value(t, p.server.remote_idx, p.client.local_idx)

	client_pub: [KEY_SIZE]byte
	ecdh.private_key_public_bytes(&p.client_key, client_pub[:])
	testing.expect_value(t, p.server.peer_key, client_pub)
}

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	p: Pair
	handshake(t, &p)

	pkt_buf, pt_buf: [MAX_PACKET_SIZE]byte
	msg := "hello"
	pkt, ok := seal(&p.client, transmute([]byte)msg, pkt_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, data_receiver_index(pkt), 42)

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
test_wrong_server_key :: proc(t: ^testing.T) {
	server_key, impostor_key, client_key: ecdh.Private_Key
	gen_key(t, &server_key)
	gen_key(t, &impostor_key)
	gen_key(t, &client_key)
	server_pub: ecdh.Public_Key
	ecdh.public_key_set_priv(&server_pub, &server_key)

	ini: Initiator
	init_packet, _ := initiator_start(&ini, &client_key, &server_pub)

	// Someone without the pinned server key cannot complete the handshake.
	sess: Session
	resp_buf: [MAX_PACKET_SIZE]byte
	_, ok := responder_accept(&impostor_key, init_packet, 7, &sess, resp_buf[:])
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
