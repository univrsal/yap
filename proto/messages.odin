package proto

import "core:encoding/endian"
import "core:time"

/*
Application messages, carried as Data plaintext. An empty plaintext is
a keepalive. Integers are little-endian.

	client -> server  Voice      [kind][seq u32][frame...]
	server -> client  Voice      [kind][speaker u32][seq u32][frame...]
	client -> server  Join       [kind][request u32][channel u16]
	server -> client  State      [kind][version u32][chunk u8][chunk_count u8][bytes...]
	client -> server  State_Ack  [kind][version u32]

Channel state is synced as full snapshots, not deltas, so loss and
reordering can't leave a client inconsistent: the server resends the
current snapshot until the client acks its version. A snapshot can be
larger than one datagram, so it is split into chunks; the client acks
once it has them all.

Join requests carry an increasing id and are resent until a snapshot's
`join_ack` reaches it. Ids are compared with serial arithmetic, and the
client continues numbering from the `join_ack` in the first snapshot it
receives, so a restarted client doesn't collide with its old ids.
*/
Message_Kind :: enum u8 {
	Voice     = 1,
	Join      = 2,
	State     = 3,
	State_Ack = 4,
}

VOICE_UP_HEADER_SIZE   :: 1 + 4
VOICE_DOWN_HEADER_SIZE :: 1 + 4 + 4
JOIN_SIZE              :: 1 + 4 + 2
STATE_HEADER_SIZE      :: 1 + 4 + 1 + 1
STATE_ACK_SIZE         :: 1 + 4

STATE_CHUNK_SIZE :: MAX_PAYLOAD_SIZE - STATE_HEADER_SIZE
MAX_STATE_CHUNKS :: 16
MAX_STATE_SIZE   :: STATE_CHUNK_SIZE * MAX_STATE_CHUNKS

// Unacked State snapshots and Join requests are resent this often.
CONTROL_RESEND :: 300 * time.Millisecond

MAX_CHANNELS          :: 64
MAX_CHANNEL_NAME_SIZE :: 32

Channel_Info :: struct {
	name:    string,
	members: []u32, // user ids (first 4 bytes of their public key)
}

// Channel_State is one user's view: channel ids are indices into `channels`.
Channel_State :: struct {
	your_channel: u16,
	join_ack:     u32,
	channels:     []Channel_Info,
}

message_kind :: proc(pt: []byte) -> (kind: Message_Kind, ok: bool) {
	if len(pt) == 0 {
		return
	}
	kind = Message_Kind(pt[0])
	switch kind {
	case .Voice:     ok = true
	case .Join:      ok = len(pt) == JOIN_SIZE
	case .State:     ok = len(pt) > STATE_HEADER_SIZE
	case .State_Ack: ok = len(pt) == STATE_ACK_SIZE
	}
	return
}

// serial_newer reports whether a is after b, allowing for wrap-around.
serial_newer :: proc(a, b: u32) -> bool {
	return i32(a - b) > 0
}

encode_join :: proc(out: ^[JOIN_SIZE]byte, request: u32, channel: u16) -> []byte {
	out[0] = u8(Message_Kind.Join)
	endian.unchecked_put_u32le(out[1:], request)
	endian.unchecked_put_u16le(out[5:], channel)
	return out[:]
}

decode_join :: proc(pt: []byte) -> (request: u32, channel: u16) {
	return endian.unchecked_get_u32le(pt[1:]), endian.unchecked_get_u16le(pt[5:])
}

encode_state_ack :: proc(out: ^[STATE_ACK_SIZE]byte, version: u32) -> []byte {
	out[0] = u8(Message_Kind.State_Ack)
	endian.unchecked_put_u32le(out[1:], version)
	return out[:]
}

decode_state_ack :: proc(pt: []byte) -> (version: u32) {
	return endian.unchecked_get_u32le(pt[1:])
}

/*
Snapshot body (before chunking):

	[your_channel u16][join_ack u32][channel_count u16]
	per channel: [name_len u8][name][member_count u16][member u32 ...]
*/
@(require_results)
encode_state :: proc(state: Channel_State, out: []byte) -> (body: []byte, ok: bool) {
	w := Writer{buf = out}
	put_u16(&w, state.your_channel)
	put_u32(&w, state.join_ack)
	put_u16(&w, u16(len(state.channels)))
	for ch in state.channels {
		if len(ch.name) > MAX_CHANNEL_NAME_SIZE || len(ch.members) > int(max(u16)) {
			return
		}
		put_u8(&w, u8(len(ch.name)))
		put_bytes(&w, transmute([]byte)ch.name)
		put_u16(&w, u16(len(ch.members)))
		for m in ch.members {
			put_u32(&w, m)
		}
	}
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_state parses a snapshot body. Names and member lists are slices
// into `body` and `members_buf`, so both must outlive the result.
@(require_results)
decode_state :: proc(body: []byte, channels_buf: []Channel_Info, members_buf: []u32) -> (state: Channel_State, ok: bool) {
	r := Reader{buf = body}
	state.your_channel = get_u16(&r)
	state.join_ack = get_u32(&r)
	count := int(get_u16(&r))
	if r.overflow || count == 0 || count > len(channels_buf) || int(state.your_channel) >= count {
		return
	}

	next_member := 0
	for &ch in channels_buf[:count] {
		name_len := int(get_u8(&r))
		ch.name = string(get_bytes(&r, name_len))
		member_count := int(get_u16(&r))
		if r.overflow || name_len > MAX_CHANNEL_NAME_SIZE || next_member + member_count > len(members_buf) {
			return
		}
		ch.members = members_buf[next_member:][:member_count]
		next_member += member_count
		for &m in ch.members {
			m = get_u32(&r)
		}
	}
	if r.overflow || r.pos != len(body) {
		return
	}
	state.channels = channels_buf[:count]
	return state, true
}

// state_chunk_count returns how many State messages a snapshot body needs.
state_chunk_count :: proc(body_len: int) -> int {
	return max(1, (body_len + STATE_CHUNK_SIZE - 1) / STATE_CHUNK_SIZE)
}

// encode_state_chunk writes chunk `index` of a snapshot body as a State message.
encode_state_chunk :: proc(out: []byte, version: u32, body: []byte, index: int) -> []byte {
	count := state_chunk_count(len(body))
	start := index * STATE_CHUNK_SIZE
	part := body[start:min(start + STATE_CHUNK_SIZE, len(body))]

	out[0] = u8(Message_Kind.State)
	endian.unchecked_put_u32le(out[1:], version)
	out[5] = u8(index)
	out[6] = u8(count)
	copy(out[STATE_HEADER_SIZE:], part)
	return out[:STATE_HEADER_SIZE + len(part)]
}

// state_message_version returns the snapshot version a State message belongs to.
state_message_version :: proc(pt: []byte) -> u32 {
	return endian.unchecked_get_u32le(pt[1:])
}

// State_Assembler collects the chunks of the newest snapshot version.
State_Assembler :: struct {
	version:  u32,
	count:    int,
	have:     [MAX_STATE_CHUNKS]bool,
	received: int,
	size:     int,
	buf:      [MAX_STATE_SIZE]byte,
}

// assembler_add feeds in a State message. When it completes a snapshot
// it returns the body, which stays valid until the next call.
@(require_results)
assembler_add :: proc(a: ^State_Assembler, pt: []byte, min_version: u32) -> (version: u32, body: []byte, complete: bool) {
	version = endian.unchecked_get_u32le(pt[1:])
	index, count := int(pt[5]), int(pt[6])
	part := pt[STATE_HEADER_SIZE:]
	if count == 0 || count > MAX_STATE_CHUNKS || index >= count ||
	   len(part) > STATE_CHUNK_SIZE || (index < count - 1 && len(part) != STATE_CHUNK_SIZE) {
		return
	}
	// Older than what the caller already has: nothing to do.
	if min_version != 0 && !serial_newer(version, min_version) {
		return
	}

	if a.count == 0 || serial_newer(version, a.version) {
		a.version, a.count, a.received, a.size = version, count, 0, 0
		a.have = {}
	} else if version != a.version || count != a.count {
		return // an older version, or inconsistent with what we have
	}

	if !a.have[index] {
		a.have[index] = true
		a.received += 1
		copy(a.buf[index * STATE_CHUNK_SIZE:], part)
		if index == count - 1 {
			a.size = index * STATE_CHUNK_SIZE + len(part)
		}
	}
	if a.received < a.count {
		return
	}
	a.count = 0 // start fresh for the next version
	return version, a.buf[:a.size], true
}

@(private)
Writer :: struct {
	buf:      []byte,
	pos:      int,
	overflow: bool,
}

@(private)
put_bytes :: proc(w: ^Writer, b: []byte) {
	if w.overflow || w.pos + len(b) > len(w.buf) {
		w.overflow = true
		return
	}
	copy(w.buf[w.pos:], b)
	w.pos += len(b)
}

@(private)
put_u8 :: proc(w: ^Writer, v: u8) {
	v := v
	put_bytes(w, ([^]byte)(&v)[:1])
}

@(private)
put_u16 :: proc(w: ^Writer, v: u16) {
	b: [2]byte
	endian.unchecked_put_u16le(b[:], v)
	put_bytes(w, b[:])
}

@(private)
put_u32 :: proc(w: ^Writer, v: u32) {
	b: [4]byte
	endian.unchecked_put_u32le(b[:], v)
	put_bytes(w, b[:])
}

@(private)
Reader :: struct {
	buf:      []byte,
	pos:      int,
	overflow: bool,
}

@(private)
get_bytes :: proc(r: ^Reader, n: int) -> []byte {
	if r.overflow || r.pos + n > len(r.buf) {
		r.overflow = true
		return nil
	}
	b := r.buf[r.pos:][:n]
	r.pos += n
	return b
}

@(private)
get_u8 :: proc(r: ^Reader) -> u8 {
	b := get_bytes(r, 1)
	return b == nil ? 0 : b[0]
}

@(private)
get_u16 :: proc(r: ^Reader) -> u16 {
	b := get_bytes(r, 2)
	return b == nil ? 0 : endian.unchecked_get_u16le(b)
}

@(private)
get_u32 :: proc(r: ^Reader) -> u32 {
	b := get_bytes(r, 4)
	return b == nil ? 0 : endian.unchecked_get_u32le(b)
}
