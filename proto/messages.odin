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
	client -> server  Leave      [kind]
	client -> server  Set_Name   [kind][name_len u8][name]
	client -> server  Sound      [kind][flags u8]
	(text chat: Chat_Send, Chat_Sent, Chat, Chat_Received, Typing; see chat.odin)

Users are identified by a number the server assigns (`speaker` in Voice,
members in State; User_Num). Numbers are unique per server run and never
reused, and State maps them to each user's full public key and name.
Clients key anything they store about a user by the public key.

A client's name first arrives in its handshake (see names.odin, Hello).
Set_Name changes it later; it's idempotent, so the client resends it until
a snapshot shows the name applied.

Sound says whether a user has muted their microphone or stopped
listening, so the others can show it. Like Set_Name it's idempotent and
resent until a snapshot agrees. It's only ever about what a user has
done to themselves: muting somebody for yourself is your business and
stays on your machine.

Leave is a courtesy so others see the user go right away instead of
after SESSION_TIMEOUT; it's unreliable, so clients send a few copies.

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
/*
User_Num is a user's number (see above). It's a type of its own so it
can't be taken for a Session_Id, the other number that goes with a
user: that one says which session a packet is for (see session.odin),
and a user may have several.
*/
User_Num :: distinct u32

Message_Kind :: enum u8 {
	Voice         = 1,
	Join          = 2,
	State         = 3,
	State_Ack     = 4,
	Leave         = 5,
	Set_Name      = 6,
	// Text chat, see chat.odin.
	Chat_Send     = 7,
	Chat_Sent     = 8,
	Chat          = 9,
	Chat_Received = 10,
	Typing        = 11,
	// Images in chat, see chat.odin and blob.odin.
	Image_Send    = 12,
	Image_Get     = 13,
	Blob_Chunk    = 14,
	Blob_Need     = 15,
	Image_Gone    = 16,
	// What a user has switched off for themselves.
	Sound         = 17,
	// One user nudging another, see poke.odin.
	Poke          = 18,
}

/*
A user's own sound state, as everyone else sees it. Muting a user for
yourself is a local setting and never goes on the wire, so what arrives
here is always what that user did to themselves.
*/
User_Flag :: enum u8 {
	Muted, // their microphone is off
	Deafened, // they aren't listening to the channel
}
User_Flags :: distinct bit_set[User_Flag;u8]

VOICE_UP_HEADER_SIZE :: 1 + 4
VOICE_DOWN_HEADER_SIZE :: 1 + 4 + 4
JOIN_SIZE :: 1 + 4 + 2
STATE_HEADER_SIZE :: 1 + 4 + 1 + 1
STATE_ACK_SIZE :: 1 + 4
SOUND_SIZE :: 1 + 1

STATE_CHUNK_SIZE :: MAX_PAYLOAD_SIZE - STATE_HEADER_SIZE
MAX_STATE_CHUNKS :: 16
MAX_STATE_SIZE :: STATE_CHUNK_SIZE * MAX_STATE_CHUNKS

// Unacked State snapshots, Join and Set_Name requests are resent this often.
CONTROL_RESEND :: 300 * time.Millisecond

MAX_CHANNELS :: 64
MAX_CHANNEL_NAME_SIZE :: 32

User_Info :: struct {
	num:   User_Num, // assigned by the server
	key:   [KEY_SIZE]u8,
	name:  string, // sanitized (see sanitize_name); may be empty
	flags: User_Flags, // what they've switched off for themselves
}

Channel_Info :: struct {
	name:    string,
	members: []User_Num,
}

// Channel_State is one user's view: channel ids are indices into `channels`.
Channel_State :: struct {
	your_channel: u16,
	your_user:    User_Num,
	join_ack:     u32,
	users:        []User_Info,
	channels:     []Channel_Info,
}

// The smallest a user takes up in a snapshot; bounds how many can be decoded.
MIN_USER_SIZE :: 4 + KEY_SIZE + 1 + 1
MAX_STATE_USERS :: MAX_STATE_SIZE / MIN_USER_SIZE

message_kind :: proc(pt: []byte) -> (kind: Message_Kind, ok: bool) {
	if len(pt) == 0 {
		return
	}
	kind = Message_Kind(pt[0])
	switch kind {
	case .Voice:
		ok = true
	case .Join:
		ok = len(pt) == JOIN_SIZE
	case .State:
		ok = len(pt) > STATE_HEADER_SIZE
	case .State_Ack:
		ok = len(pt) == STATE_ACK_SIZE
	case .Leave:
		ok = len(pt) == 1
	case .Set_Name:
		ok = len(pt) >= 2 && int(pt[1]) <= MAX_NAME_SIZE && len(pt) == 2 + int(pt[1])
	case .Sound:
		ok = len(pt) == SOUND_SIZE
	case .Chat_Send:
		ok =
			len(pt) >= CHAT_SEND_HEADER_SIZE &&
			len(pt) == CHAT_SEND_HEADER_SIZE + int(endian.unchecked_get_u16le(pt[9:])) &&
			len(pt) - CHAT_SEND_HEADER_SIZE <= MAX_CHAT_SIZE
	case .Chat_Sent:
		ok = len(pt) == CHAT_SENT_SIZE
	case .Chat:
		ok = len(pt) >= CHAT_HEADER_SIZE
	case .Chat_Received:
		ok = len(pt) == CHAT_RECEIVED_SIZE
	case .Poke:
		ok = len(pt) >= POKE_HEADER_SIZE && len(pt) == POKE_HEADER_SIZE + int(pt[9])
	case .Typing:
		ok = len(pt) == TYPING_UP_SIZE || len(pt) == TYPING_DOWN_SIZE
	case .Image_Send:
		ok = len(pt) == IMAGE_SEND_SIZE
	case .Image_Get:
		ok = len(pt) == IMAGE_GET_SIZE
	case .Image_Gone:
		ok = len(pt) == IMAGE_GONE_SIZE
	case .Blob_Chunk:
		ok =
			len(pt) > BLOB_CHUNK_HEADER_SIZE && len(pt) <= BLOB_CHUNK_HEADER_SIZE + BLOB_CHUNK_SIZE
	case .Blob_Need:
		ok = len(pt) >= BLOB_NEED_HEADER_SIZE
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

SET_NAME_MAX_SIZE :: 2 + MAX_NAME_SIZE

// encode_set_name expects an already sanitized name.
encode_set_name :: proc(out: ^[SET_NAME_MAX_SIZE]byte, name: string) -> []byte {
	n := min(len(name), MAX_NAME_SIZE)
	out[0] = u8(Message_Kind.Set_Name)
	out[1] = u8(n)
	copy(out[2:], name[:n])
	return out[:2 + n]
}

// decode_set_name returns the raw name; sanitize it before use.
decode_set_name :: proc(pt: []byte) -> string {
	return string(pt[2:][:pt[1]])
}

encode_sound :: proc(out: ^[SOUND_SIZE]byte, flags: User_Flags) -> []byte {
	out[0] = u8(Message_Kind.Sound)
	out[1] = transmute(u8)flags
	return out[:]
}

// decode_sound keeps flags this build doesn't know: a newer client may
// have switched off something we have no name for yet.
decode_sound :: proc(pt: []byte) -> User_Flags {
	return transmute(User_Flags)pt[1]
}

/*
Snapshot body (before chunking):

	[your_channel u16][your_user u32][join_ack u32]
	[user_count u16]    per user:    [num u32][key 32 bytes][flags u8][name_len u8][name]
	[channel_count u16] per channel: [name_len u8][name][member_count u16][member num u32 ...]
*/
@(require_results)
encode_state :: proc(state: Channel_State, out: []byte) -> (body: []byte, ok: bool) {
	w := Writer {
		buf = out,
	}
	put_u16(&w, state.your_channel)
	put_u32(&w, u32(state.your_user))
	put_u32(&w, state.join_ack)

	if len(state.users) > int(max(u16)) {
		return
	}
	put_u16(&w, u16(len(state.users)))
	for &u in state.users {
		if len(u.name) > MAX_NAME_SIZE {
			return
		}
		put_u32(&w, u32(u.num))
		put_bytes(&w, u.key[:])
		put_u8(&w, transmute(u8)u.flags)
		put_u8(&w, u8(len(u.name)))
		put_bytes(&w, transmute([]byte)u.name)
	}

	put_u16(&w, u16(len(state.channels)))
	for ch in state.channels {
		if len(ch.name) > MAX_CHANNEL_NAME_SIZE || len(ch.members) > int(max(u16)) {
			return
		}
		put_u8(&w, u8(len(ch.name)))
		put_bytes(&w, transmute([]byte)ch.name)
		put_u16(&w, u16(len(ch.members)))
		for m in ch.members {
			put_u32(&w, u32(m))
		}
	}
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_state parses a snapshot body. Names and lists are slices into
// `body` and the buffers, so all of them must outlive the result.
@(require_results)
decode_state :: proc(
	body: []byte,
	users_buf: []User_Info,
	channels_buf: []Channel_Info,
	members_buf: []User_Num,
) -> (
	state: Channel_State,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	state.your_channel = get_u16(&r)
	state.your_user = User_Num(get_u32(&r))
	state.join_ack = get_u32(&r)

	user_count := int(get_u16(&r))
	if r.overflow || user_count > len(users_buf) {
		return
	}
	for &u in users_buf[:user_count] {
		u.num = User_Num(get_u32(&r))
		copy(u.key[:], get_bytes(&r, KEY_SIZE))
		u.flags = transmute(User_Flags)get_u8(&r)
		name_len := int(get_u8(&r))
		u.name = string(get_bytes(&r, name_len))
		if r.overflow || name_len > MAX_NAME_SIZE {
			return
		}
	}

	count := int(get_u16(&r))
	if r.overflow || count == 0 || count > len(channels_buf) || int(state.your_channel) >= count {
		return
	}
	next_member := 0
	for &ch in channels_buf[:count] {
		name_len := int(get_u8(&r))
		ch.name = string(get_bytes(&r, name_len))
		member_count := int(get_u16(&r))
		if r.overflow ||
		   name_len > MAX_CHANNEL_NAME_SIZE ||
		   next_member + member_count > len(members_buf) {
			return
		}
		ch.members = members_buf[next_member:][:member_count]
		next_member += member_count
		for &m in ch.members {
			m = User_Num(get_u32(&r))
		}
	}
	if r.overflow || r.pos != len(body) {
		return
	}
	state.users = users_buf[:user_count]
	state.channels = channels_buf[:count]
	return state, true
}

// find_user returns the user with number `num` in a snapshot, or nil.
find_user :: proc(state: ^Channel_State, num: User_Num) -> ^User_Info {
	for &u in state.users {
		if u.num == num {
			return &u
		}
	}
	return nil
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
assembler_add :: proc(
	a: ^State_Assembler,
	pt: []byte,
	min_version: u32,
) -> (
	version: u32,
	body: []byte,
	complete: bool,
) {
	version = endian.unchecked_get_u32le(pt[1:])
	index, count := int(pt[5]), int(pt[6])
	part := pt[STATE_HEADER_SIZE:]
	if count == 0 ||
	   count > MAX_STATE_CHUNKS ||
	   index >= count ||
	   len(part) > STATE_CHUNK_SIZE ||
	   (index < count - 1 && len(part) != STATE_CHUNK_SIZE) {
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
