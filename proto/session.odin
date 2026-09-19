package proto

import "core:crypto"
import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:encoding/endian"
import "core:time"

// Session is an established, keyed connection to one peer.
Session :: struct {
	local_idx:  u32, // peers address packets to us with this
	remote_idx: u32, // we address packets to the peer with this
	cs:         noise.Cipher_States,
	send_n:     u64,
	replay:     Replay_Window,
	peer_key:   [KEY_SIZE]byte, // peer's static public key
	created:    time.Tick,
}

Initiator_State :: enum {
	Idle,
	Sent_Init, // waiting for Handshake_Resp
	Sent_Finish, // keys derived; waiting for the server to confirm
}

// Initiator is the client side of an in-progress handshake.
Initiator :: struct {
	hs:         noise.Handshake_State,
	state:      Initiator_State,
	local_idx:  u32,
	remote_idx: u32,
	started:    time.Tick,
	last_sent:  time.Tick,
	// The last handshake packet sent, kept to retransmit verbatim if lost.
	packet:     [MAX_PACKET_SIZE]byte,
	packet_len: int,
}

// Responder is the server side of an in-progress handshake.
Responder :: struct {
	hs:         noise.Handshake_State,
	local_idx:  u32,
	remote_idx: u32,
	// Handshake_Resp, kept to answer a retransmitted Handshake_Init.
	packet:     [RESP_SIZE]byte,
}

session_reset :: proc(s: ^Session) {
	noise.cipherstates_reset(&s.cs)
	s^ = {}
}

initiator_reset :: proc(ini: ^Initiator) {
	noise.handshake_reset(&ini.hs)
	ini^ = {}
}

responder_reset :: proc(r: ^Responder) {
	noise.handshake_reset(&r.hs)
	r^ = {}
}

initiator_packet :: proc(ini: ^Initiator) -> []byte {
	return ini.packet[:ini.packet_len]
}

random_index :: proc() -> u32 {
	idx: u32
	for idx == 0 {
		crypto.rand_bytes(([^]byte)(&idx)[:size_of(idx)])
	}
	return idx
}

// receiver_index returns the session index a Handshake_Finish or Data
// packet is addressed to.
receiver_index :: proc(packet: []byte) -> u32 {
	return endian.unchecked_get_u32le(packet[1:])
}

// init_sender_index returns the client's index from a Handshake_Init.
init_sender_index :: proc(packet: []byte) -> u32 {
	return endian.unchecked_get_u32le(packet[1:])
}

@(private)
prologue :: proc() -> []byte {
	s := PROLOGUE
	return transmute([]byte)s
}

// initiator_start begins a handshake and returns the Handshake_Init packet.
@(require_results)
initiator_start :: proc(
	ini: ^Initiator,
	static_key: ^ecdh.Private_Key,
) -> (
	packet: []byte,
	ok: bool,
) {
	initiator_reset(ini)

	if noise.handshake_init(&ini.hs, true, prologue(), static_key, nil, PROTOCOL_NAME) != .Ok {
		return
	}

	padding: [INIT_PADDING]byte
	msg, status := noise.handshake_write_message(&ini.hs, padding[:], nil, context.temp_allocator)
	if status != .Handshake_Pending || INIT_HEADER_SIZE + len(msg) != INIT_SIZE {
		return
	}

	ini.state = .Sent_Init
	ini.local_idx = random_index()
	ini.started = time.tick_now()

	ini.packet[0] = u8(Packet_Type.Handshake_Init)
	endian.unchecked_put_u32le(ini.packet[1:], ini.local_idx)
	copy(ini.packet[INIT_HEADER_SIZE:], msg)
	ini.packet_len = INIT_SIZE
	return initiator_packet(ini), true
}

Resp_Result :: enum {
	Ignored, // not addressed to this handshake; keep waiting
	Failed, // addressed to us but invalid; the Initiator has been reset
	Ok,
}

// initiator_read_resp processes a Handshake_Resp and returns the
// server's static public key. The caller must decide whether to trust
// that key before calling initiator_finish, which is the point where our
// own identity gets sent.
@(require_results)
initiator_read_resp :: proc(
	ini: ^Initiator,
	packet: []byte,
) -> (
	server_key: [KEY_SIZE]byte,
	result: Resp_Result,
) {
	if ini.state != .Sent_Init || packet_type(packet) != .Handshake_Resp {
		return
	}
	remote_idx := endian.unchecked_get_u32le(packet[1:])
	receiver_idx := endian.unchecked_get_u32le(packet[5:])
	if receiver_idx != ini.local_idx {
		return
	}

	// A failed read leaves the Noise state unusable, so start over.
	_, status := noise.handshake_read_message(
		&ini.hs,
		packet[RESP_HEADER_SIZE:],
		nil,
		context.temp_allocator,
	)
	if status != .Handshake_Pending {
		initiator_reset(ini)
		return {}, .Failed
	}

	ini.remote_idx = remote_idx
	ecdh.public_key_bytes(&ini.hs.rs, server_key[:])
	return server_key, .Ok
}

// initiator_finish sends our static key (plus an optional encrypted
// payload), derives the session keys into `sess`, and returns the
// Handshake_Finish packet. The Initiator keeps the packet so it can be
// resent until the server confirms with its first Data packet.
@(require_results)
initiator_finish :: proc(
	ini: ^Initiator,
	sess: ^Session,
	payload: []byte = nil,
) -> (
	packet: []byte,
	ok: bool,
) {
	if ini.state != .Sent_Init || ini.remote_idx == 0 {
		return
	}

	msg, status := noise.handshake_write_message(&ini.hs, payload, nil, context.temp_allocator)
	if status != .Handshake_Complete || FINISH_HEADER_SIZE + len(msg) > MAX_PACKET_SIZE {
		initiator_reset(ini)
		return
	}

	session_reset(sess)
	if noise.handshake_split(&ini.hs, &sess.cs) != .Ok {
		initiator_reset(ini)
		return
	}
	ecdh.public_key_bytes(&ini.hs.rs, sess.peer_key[:])
	sess.local_idx = ini.local_idx
	sess.remote_idx = ini.remote_idx
	sess.created = time.tick_now()

	// Keys are copied out; wipe the handshake secrets but keep the packet.
	noise.handshake_reset(&ini.hs)
	ini.state = .Sent_Finish
	ini.packet[0] = u8(Packet_Type.Handshake_Finish)
	endian.unchecked_put_u32le(ini.packet[1:], ini.remote_idx)
	copy(ini.packet[FINISH_HEADER_SIZE:], msg)
	ini.packet_len = FINISH_HEADER_SIZE + len(msg)
	return initiator_packet(ini), true
}

// responder_start processes a Handshake_Init on the server and returns
// the Handshake_Resp packet, which the Responder also keeps.
@(require_results)
responder_start :: proc(
	r: ^Responder,
	static_key: ^ecdh.Private_Key,
	packet: []byte,
	local_idx: u32,
) -> (
	resp: []byte,
	ok: bool,
) {
	responder_reset(r)
	if packet_type(packet) != .Handshake_Init {
		return
	}

	if noise.handshake_init(&r.hs, false, prologue(), static_key, nil, PROTOCOL_NAME) != .Ok {
		return
	}
	// The msg1 payload is just padding, so it's ignored.
	msg, _, status := noise.handshake_responder_step(
		&r.hs,
		packet[INIT_HEADER_SIZE:],
		nil,
		nil,
		context.temp_allocator,
	)
	if status != .Handshake_Pending || len(msg) != MSG2_SIZE {
		responder_reset(r)
		return
	}

	r.local_idx = local_idx
	r.remote_idx = init_sender_index(packet)
	r.packet[0] = u8(Packet_Type.Handshake_Resp)
	endian.unchecked_put_u32le(r.packet[1:], r.local_idx)
	endian.unchecked_put_u32le(r.packet[5:], r.remote_idx)
	copy(r.packet[RESP_HEADER_SIZE:], msg)
	return r.packet[:], true
}

// responder_finish processes a Handshake_Finish. On success it fills in
// `sess` (with the client's static key in peer_key) and returns the msg3
// payload. The Responder is reset either way: Noise handshake state
// can't be reused after a failed read.
@(require_results)
responder_finish :: proc(
	r: ^Responder,
	packet: []byte,
	sess: ^Session,
) -> (
	payload: []byte,
	ok: bool,
) {
	defer responder_reset(r)
	if r.local_idx == 0 ||
	   packet_type(packet) != .Handshake_Finish ||
	   receiver_index(packet) != r.local_idx {
		return
	}

	pt, status := noise.handshake_read_message(
		&r.hs,
		packet[FINISH_HEADER_SIZE:],
		nil,
		context.temp_allocator,
	)
	if status != .Handshake_Complete {
		return
	}

	session_reset(sess)
	if noise.handshake_split(&r.hs, &sess.cs) != .Ok {
		return
	}
	peer, _ := noise.handshake_peer_identity(&r.hs)
	ecdh.public_key_bytes(peer, sess.peer_key[:])
	sess.local_idx = r.local_idx
	sess.remote_idx = r.remote_idx
	sess.created = time.tick_now()
	return pt, true
}

// seal encrypts `plaintext` into a Data packet written to `out`.
@(require_results)
seal :: proc(s: ^Session, plaintext: []byte, out: []byte) -> (packet: []byte, ok: bool) {
	n := DATA_HEADER_SIZE + len(plaintext) + TAG_SIZE
	if len(plaintext) > MAX_PAYLOAD_SIZE || len(out) < n || s.send_n >= REJECT_AFTER_MESSAGES {
		return
	}

	out[0] = u8(Packet_Type.Data)
	endian.unchecked_put_u32le(out[1:], s.remote_idx)
	endian.unchecked_put_u64le(out[5:], s.send_n)

	// Noise's own counter already tracks send_n; setting it explicitly
	// keeps the nonce and the on-wire counter visibly identical.
	if noise.cipherstates_set_n(&s.cs, true, s.send_n) != .Ok {
		return
	}
	if _, status := noise.seal_message(
		&s.cs,
		out[:DATA_HEADER_SIZE],
		plaintext,
		out[DATA_HEADER_SIZE:n],
	); status != .Ok {
		return
	}
	s.send_n += 1
	return out[:n], true
}

// open authenticates and decrypts a Data packet into `out`. Replayed,
// too-old, or forged packets are rejected.
@(require_results)
open :: proc(s: ^Session, packet: []byte, out: []byte) -> (plaintext: []byte, ok: bool) {
	if packet_type(packet) != .Data {
		return
	}
	counter := endian.unchecked_get_u64le(packet[5:])
	if counter >= REJECT_AFTER_MESSAGES || !replay_check(&s.replay, counter) {
		return
	}

	ciphertext := packet[DATA_HEADER_SIZE:]
	pt_len := len(ciphertext) - TAG_SIZE
	if len(out) < pt_len {
		return
	}

	if noise.cipherstates_set_n(&s.cs, false, counter) != .Ok {
		return
	}
	pt, status := noise.open_message(&s.cs, packet[:DATA_HEADER_SIZE], ciphertext, out[:pt_len])
	if status != .Ok {
		return
	}

	// Only mark the counter seen once the packet is proven authentic,
	// otherwise forged packets could poison the window.
	replay_update(&s.replay, counter)
	return pt, true
}

// Replay_Window is a 64-packet sliding window (RFC 6479 style). At
// 50 packets/s that is ~1.3 s of reordering tolerance, which is longer
// than any jitter buffer would wait for a late voice frame anyway.
Replay_Window :: struct {
	max:  u64, // highest counter accepted so far
	bits: u64, // bit i set => counter (max - i) was seen
	init: bool,
}

REPLAY_WINDOW_SIZE :: 64

replay_check :: proc(w: ^Replay_Window, n: u64) -> bool {
	if !w.init || n > w.max {
		return true
	}
	diff := w.max - n
	if diff >= REPLAY_WINDOW_SIZE {
		return false
	}
	return w.bits & (u64(1) << diff) == 0
}

replay_update :: proc(w: ^Replay_Window, n: u64) {
	switch {
	case !w.init:
		w.init, w.max, w.bits = true, n, 1
	case n > w.max:
		shift := n - w.max
		w.bits = shift >= REPLAY_WINDOW_SIZE ? 0 : w.bits << shift
		w.bits |= 1
		w.max = n
	case:
		w.bits |= u64(1) << (w.max - n)
	}
}
