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

// Initiator is the client side of an in-progress handshake.
Initiator :: struct {
	hs:        noise.Handshake_State,
	local_idx: u32,
	started:   time.Tick,
	last_sent: time.Tick,
	// msg1 is kept so it can be retransmitted verbatim if lost.
	packet:     [MAX_PACKET_SIZE]byte,
	packet_len: int,
}

session_reset :: proc(s: ^Session) {
	noise.cipherstates_reset(&s.cs)
	s^ = {}
}

initiator_reset :: proc(ini: ^Initiator) {
	noise.handshake_reset(&ini.hs)
	ini^ = {}
}

random_index :: proc() -> u32 {
	idx: u32
	for idx == 0 {
		crypto.rand_bytes(([^]byte)(&idx)[:size_of(idx)])
	}
	return idx
}

// initiator_start begins a handshake and returns the Handshake_Init packet.
@(require_results)
initiator_start :: proc(
	ini: ^Initiator,
	static_key: ^ecdh.Private_Key,
	server_key: ^ecdh.Public_Key,
) -> (packet: []byte, ok: bool) {
	initiator_reset(ini)

	prologue := PROLOGUE
	if noise.handshake_init(&ini.hs, true, transmute([]byte)prologue, static_key, server_key, PROTOCOL_NAME) != .Ok {
		return
	}

	msg, _, status := noise.handshake_initiator_step(&ini.hs, nil, nil, nil, context.temp_allocator)
	if status != .Handshake_Pending || INIT_HEADER_SIZE + len(msg) > MAX_PACKET_SIZE {
		return
	}

	ini.local_idx = random_index()
	ini.started = time.tick_now()

	ini.packet[0] = u8(Packet_Type.Handshake_Init)
	endian.unchecked_put_u32le(ini.packet[1:], ini.local_idx)
	copy(ini.packet[INIT_HEADER_SIZE:], msg)
	ini.packet_len = INIT_HEADER_SIZE + len(msg)

	return ini.packet[:ini.packet_len], true
}

// initiator_finish consumes a Handshake_Resp and, on success, fills in
// a new Session. The Initiator is reset either way if the packet was
// addressed to it.
@(require_results)
initiator_finish :: proc(ini: ^Initiator, packet: []byte, sess: ^Session) -> bool {
	if packet_type(packet) != .Handshake_Resp {
		return false
	}
	remote_idx := endian.unchecked_get_u32le(packet[1:])
	receiver_idx := endian.unchecked_get_u32le(packet[5:])
	if ini.local_idx == 0 || receiver_idx != ini.local_idx {
		return false // stale or not ours; keep waiting
	}

	_, _, status := noise.handshake_initiator_step(&ini.hs, packet[RESP_HEADER_SIZE:], nil, nil, context.temp_allocator)
	defer initiator_reset(ini)
	if status != .Handshake_Complete {
		return false
	}

	session_reset(sess)
	if noise.handshake_split(&ini.hs, &sess.cs) != .Ok {
		return false
	}
	peer, _ := noise.handshake_peer_identity(&ini.hs)
	ecdh.public_key_bytes(peer, sess.peer_key[:])
	sess.local_idx = ini.local_idx
	sess.remote_idx = remote_idx
	sess.created = time.tick_now()
	return true
}

// responder_accept processes a Handshake_Init on the server. On success
// it fills in `sess` (keyed, with the client's static key in peer_key)
// and writes the Handshake_Resp packet into `out`.
//
// The session is not yet confirmed: IK gives the server no proof the
// client completed the handshake until the first valid Data packet
// arrives, so callers should not send to it before then.
@(require_results)
responder_accept :: proc(
	static_key: ^ecdh.Private_Key,
	packet: []byte,
	local_idx: u32,
	sess: ^Session,
	out: []byte,
) -> (resp: []byte, ok: bool) {
	if packet_type(packet) != .Handshake_Init {
		return
	}
	remote_idx := endian.unchecked_get_u32le(packet[1:])

	hs: noise.Handshake_State
	defer noise.handshake_reset(&hs)

	prologue := PROLOGUE
	if noise.handshake_init(&hs, false, transmute([]byte)prologue, static_key, nil, PROTOCOL_NAME) != .Ok {
		return
	}

	msg, _, status := noise.handshake_responder_step(&hs, packet[INIT_HEADER_SIZE:], nil, nil, context.temp_allocator)
	if status != .Handshake_Complete || len(out) < RESP_HEADER_SIZE + len(msg) {
		return
	}

	session_reset(sess)
	if noise.handshake_split(&hs, &sess.cs) != .Ok {
		return
	}
	peer, _ := noise.handshake_peer_identity(&hs)
	ecdh.public_key_bytes(peer, sess.peer_key[:])
	sess.local_idx = local_idx
	sess.remote_idx = remote_idx
	sess.created = time.tick_now()

	out[0] = u8(Packet_Type.Handshake_Resp)
	endian.unchecked_put_u32le(out[1:], local_idx)
	endian.unchecked_put_u32le(out[5:], remote_idx)
	copy(out[RESP_HEADER_SIZE:], msg)
	return out[:RESP_HEADER_SIZE + len(msg)], true
}

// data_receiver_index returns the session index a Data packet is addressed to.
data_receiver_index :: proc(packet: []byte) -> u32 {
	return endian.unchecked_get_u32le(packet[1:])
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
	if _, status := noise.seal_message(&s.cs, out[:DATA_HEADER_SIZE], plaintext, out[DATA_HEADER_SIZE:n]); status != .Ok {
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
