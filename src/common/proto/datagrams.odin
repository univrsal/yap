package proto

import "core:encoding/endian"
import "core:time"

// Application messages, carried as Data plaintext. An empty plaintext is a
// keepalive. Integers are little-endian.
//
// 	client -> server  Voice      [kind][seq u32][frame...]
// 	server -> client  Voice      [kind][speaker u32][seq u32][frame...]
// 	server -> client  State      [kind][version u32][chunk u8][chunk_count u8][bytes...]
// 	client -> server  State_Ack  [kind][version u32]
// 	client -> server  Leave      [kind]
// 	client -> server  Sound      [kind][flags u8]
// 	server -> client  Refused    [kind][reason u8]
// 	(who is typing: Typing; see messages.odin)
// 	(pictures and such, in chunks: Blob_Chunk, Blob_Need; see blob.odin)
// 	(screen sharing: Video, Watch, Keyframe; see video.odin)
// 	(connection quality: Ping, Pong; see ping.odin)
// 	(files in DMs: File_Accept, File_Chunk, File_Ack, File_Cancel; see files.odin)
// 	(what a new session belongs to: Welcome; see hello.odin)
// 	(reliable messages: Stream, Stream_Ack; see stream.odin, and rpc.odin
// 	 for what travels on it)
//
// Connections are identified by a number that the server assigns (`speaker` in
// Voice, and a user in State; User_Num). The numbers are unique per server run
// and never reused. State maps them to each connection's account (see
// accounts.odin, which is also where names come from) and to the voice room
// that the connection is in, if any (convs.odin). Only connections that are
// logged in appear in it. A device's key isn't told to other clients, because
// nothing between clients goes by it any more.
//
// Sound says whether a user has muted their microphone or stopped listening, so
// that the others can show it. It is idempotent and is resent until a snapshot
// agrees. It only ever describes what a user has done to themselves. Muting
// somebody for yourself is a local matter and stays on your machine. Sound also
// says whether the user is sharing their screen, which is the same kind of
// information: the user's own state, for others to see.
//
// Refused is the server's answer to a hello that it won't accept (see
// hello.odin). It is sent on the session that the hello's handshake created,
// which the server then drops. It is the first Data that the client sees on
// that session, so it arrives instead of the Welcome, and because it is sealed
// nobody else can forge it. It is unreliable, so the server sends a few
// copies. If they are all lost, the client's handshake times out and the next
// one is refused again.
//
// Leave is a courtesy that lets others see the user go right away instead of
// after SESSION_TIMEOUT. It is unreliable, so clients send a few copies.
//
// Who is connected, and in which room, is synced as full snapshots instead of
// deltas, so that loss and reordering can't leave a client inconsistent. The
// server resends the current snapshot until the client acknowledges its
// version. A snapshot can be larger than one datagram, so it is split into
// chunks. The client acknowledges it once it has received all of them.
//
// User_Num is a user's number (see above). It is a type of its own so that it
// can't be mistaken for a Session_Id, the other number that goes with a user.
// A Session_Id says which session a packet is for (see session.odin), and a
// user may have several sessions.
User_Num :: distinct u32

// The numbers missing below belong to retired kinds (2, 6-10, 12, 13, 16,
// 18, 25-33, 38, 39; see the version history in hello.odin). A client old
// enough to send one doesn't get past the hello, and message_kind rejects
// them like any other unknown byte.
Message_Kind :: enum u8 {
	Voice           = 1,
	State           = 3,
	State_Ack       = 4,
	Leave           = 5,
	// Who is typing and where, see messages.odin.
	Typing          = 11,
	// A blob's chunks, see blob.odin.
	Blob_Chunk      = 14,
	Blob_Need       = 15,
	// What a user has switched off for themselves.
	Sound           = 17,
	// The server refuses us (see Refusal).
	Refused         = 19,
	// Screen sharing, see video.odin.
	Video           = 20,
	Watch           = 21,
	Keyframe        = 22,
	// Measuring the connection, see ping.odin.
	Ping            = 23,
	Pong            = 24,
	// File transfers, see files.odin.
	File_Accept     = 34,
	File_Chunk      = 35,
	File_Ack        = 36,
	File_Cancel     = 37,
	// The server's answer to a hello that it accepts, see hello.odin.
	Welcome         = 40,
	// The reliable stream, see stream.odin.
	Stream          = 41,
	Stream_Ack      = 42,
	// Attachments that are transferred to and from the server, see
	// transfer.odin and attachments.odin.
	Upload_Chunk    = 43,
	Upload_Ack      = 44,
	Download_Chunk  = 45,
	Download_Ack    = 46,
	Transfer_Cancel = 47,
	// Requests to resend fragments of a shared screen, sent on the media
	// link (video_window.odin).
	Nack            = 48,
	// Reports about how well a shared screen reaches its viewers, which are
	// used to adjust its bitrate (video_report.odin).
	Report          = 49,
	// How big a camera's viewers show it, and how many there are (video.odin).
	Demand          = 50,
}

// The reason why the server refused a hello.
Refusal :: enum u8 {
	Wrong_Password    = 1, // missing, or not the server's password
	Version           = 2, // a hello that this server can't read
	// A bulk link's hello names no connection of this device (see Link in
	// hello.odin). Either the connection is gone or the main link hasn't been
	// welcomed yet.
	No_Connection     = 3,
	// Another client with the same key is connected and still in use, for
	// example an old copy of the client that was left open. Only one client
	// may use a key at a time.
	Already_Connected = 4,
}

// A user's own state as everyone else sees it: what they have switched off for
// themselves, whether they are sharing their screen, and which codecs their
// client can decode for a screen share. Muting a user for yourself is a local
// setting and is never sent over the wire, so what arrives here is always what
// that user did to themselves.
User_Flag :: enum u8 {
	Muted, // their microphone is off
	Deafened, // they aren't listening to the channel
	Sharing, // their screen can be watched (see video.odin)
	// Besides H.264, which every client decodes, a sharer encodes in whatever
	// codecs everyone in the room can decode (decodable_codecs). A client that is
	// too old to say counts as H.264 only.
	Decodes_HEVC,
	Decodes_AV1,
	// They are talking in a voice room or in a call, unless they chose not to
	// show it (SETTING_VOICE_SHOWN). Which room it is isn't said here; see
	// `room` for that, which is 0 for a room the receiver may not know about.
	// The server sets them for a room on this server. A client sends one of
	// them when it is talking on another server it is connected to, which the
	// server shows while the user isn't in a room of its own.
	In_Voice,
	In_Call,
	// Their camera is on (see video.odin). The server takes it off again
	// while their room already has as many cameras as it allows.
	Camera,
}
User_Flags :: distinct bit_set[User_Flag;u8]

// The flags that say that a user is talking (see In_Voice).
TALKING :: User_Flags{.In_Voice, .In_Call}

VOICE_UP_HEADER_SIZE :: 1 + 4
VOICE_DOWN_HEADER_SIZE :: 1 + 4 + 4
STATE_HEADER_SIZE :: 1 + 4 + 1 + 1
STATE_ACK_SIZE :: 1 + 4
SOUND_SIZE :: 1 + 1
REFUSED_SIZE :: 1 + 1

STATE_CHUNK_SIZE :: MAX_PAYLOAD_SIZE - STATE_HEADER_SIZE
MAX_STATE_CHUNKS :: 16
MAX_STATE_SIZE :: STATE_CHUNK_SIZE * MAX_STATE_CHUNKS

// The interval at which unacknowledged State snapshots and Sound messages are
// resent.
CONTROL_RESEND :: 300 * time.Millisecond

// The maximum number of channels that a server may have, and the maximum
// length of a channel name. A client is told about the channels that it is in
// and finds the others a page at a time (Conv_Browse).
// Both as Mattermost allows by default (2000 channels in a team, names of 64
// characters at up to 4 bytes each).
MAX_CHANNELS :: 2000
MAX_CHANNEL_NAME_SIZE :: 4 * 64

User_Info :: struct {
	num:     User_Num, // assigned by the server
	account: Account_Id, // the account that the connection belongs to
	flags:   User_Flags, // what they have switched off for themselves
	room:    Room, // where their voice goes, or 0 for nowhere
}

// Presence is a snapshot of every connection that is logged in, including
// which one of them belongs to the receiver.
Presence :: struct {
	your_user: User_Num,
	users:     []User_Info,
}

// The size of one user in a snapshot. It limits how many users can be decoded.
USER_SIZE :: 4 + 4 + 1 + 4
MAX_STATE_USERS :: MAX_STATE_SIZE / USER_SIZE

message_kind :: proc(pt: []byte) -> (kind: Message_Kind, ok: bool) {
	if len(pt) == 0 {
		return
	}
	kind = Message_Kind(pt[0])
	switch kind {
	case .Voice:
		ok = true
	case .State:
		ok = len(pt) > STATE_HEADER_SIZE
	case .State_Ack:
		ok = len(pt) == STATE_ACK_SIZE
	case .Leave:
		ok = len(pt) == 1
	case .Sound:
		ok = len(pt) == SOUND_SIZE
	case .Refused:
		ok = len(pt) == REFUSED_SIZE
	case .Typing:
		ok = len(pt) == TYPING_UP_SIZE || len(pt) == TYPING_DOWN_SIZE
	case .Blob_Chunk:
		ok =
			len(pt) > BLOB_CHUNK_HEADER_SIZE && len(pt) <= BLOB_CHUNK_HEADER_SIZE + BLOB_CHUNK_SIZE
	case .Blob_Need:
		ok = len(pt) >= BLOB_NEED_HEADER_SIZE
	case .Video:
		// The up and down directions differ, so decode_video_up and
		// decode_video_down check the rest.
		ok = len(pt) > VIDEO_UP_HEADER_SIZE
	case .Watch:
		ok = len(pt) == WATCH_SIZE || len(pt) == WATCH_TILE_SIZE
	case .Demand:
		ok = len(pt) == DEMAND_SIZE
	case .Keyframe:
		ok = len(pt) == KEYFRAME_SIZE || len(pt) == KEYFRAME_CAMERA_SIZE
	case .Nack:
		ok = len(pt) == NACK_SIZE || len(pt) == NACK_CAMERA_SIZE
	case .Report:
		ok = len(pt) == REPORT_SIZE || len(pt) == REPORT_CAMERA_SIZE
	case .Ping, .Pong:
		ok = len(pt) == PING_SIZE
	case .File_Accept:
		ok = len(pt) == FILE_ACCEPT_SIZE
	case .File_Chunk:
		ok = len(pt) > FILE_CHUNK_HEADER_SIZE
	case .File_Ack:
		ok = len(pt) >= FILE_ACK_HEADER_SIZE
	case .File_Cancel:
		ok = len(pt) == FILE_CANCEL_SIZE
	case .Welcome:
		ok = len(pt) == WELCOME_SIZE
	case .Stream:
		ok = len(pt) > STREAM_HEADER_SIZE
	case .Stream_Ack:
		ok = len(pt) == STREAM_ACK_SIZE
	case .Upload_Chunk, .Download_Chunk:
		ok = len(pt) > FILE_CHUNK_HEADER_SIZE
	case .Upload_Ack, .Download_Ack:
		ok = len(pt) >= FILE_ACK_HEADER_SIZE
	case .Transfer_Cancel:
		ok = len(pt) == TRANSFER_CANCEL_SIZE
	}
	return
}

// serial_newer reports whether a is after b, allowing for wrap-around.
serial_newer :: proc(a, b: u32) -> bool {
	return i32(a - b) > 0
}

encode_state_ack :: proc(out: ^[STATE_ACK_SIZE]byte, version: u32) -> []byte {
	out[0] = u8(Message_Kind.State_Ack)
	endian.unchecked_put_u32le(out[1:], version)
	return out[:]
}

decode_state_ack :: proc(pt: []byte) -> (version: u32) {
	return endian.unchecked_get_u32le(pt[1:])
}

encode_sound :: proc(out: ^[SOUND_SIZE]byte, flags: User_Flags) -> []byte {
	out[0] = u8(Message_Kind.Sound)
	out[1] = transmute(u8)flags
	return out[:]
}

// decode_sound keeps flags that this build doesn't know, because a newer client
// may have switched off something that we don't have a name for yet.
decode_sound :: proc(pt: []byte) -> User_Flags {
	return transmute(User_Flags)pt[1]
}

encode_refused :: proc(out: ^[REFUSED_SIZE]byte, reason: Refusal) -> []byte {
	out[0] = u8(Message_Kind.Refused)
	out[1] = u8(reason)
	return out[:]
}

// decode_refused may return a reason that this build doesn't have a name for.
decode_refused :: proc(pt: []byte) -> Refusal {
	return Refusal(pt[1])
}

// Snapshot body (before chunking):
//
// 	[your_user u32]
// 	[user_count u16] per user: [num u32][account u32][flags u8][room u32]
@(require_results)
encode_state :: proc(state: Presence, out: []byte) -> (body: []byte, ok: bool) {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(state.your_user))
	if len(state.users) > int(max(u16)) {
		return
	}
	put_u16(&w, u16(len(state.users)))
	for &u in state.users {
		put_u32(&w, u32(u.num))
		put_u32(&w, u32(u.account))
		put_u8(&w, transmute(u8)u.flags)
		put_u32(&w, u32(u.room))
	}
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_state parses a snapshot body into `users_buf`.
@(require_results)
decode_state :: proc(body: []byte, users_buf: []User_Info) -> (state: Presence, ok: bool) {
	r := Reader {
		buf = body,
	}
	state.your_user = User_Num(get_u32(&r))
	user_count := int(get_u16(&r))
	if r.overflow || user_count > len(users_buf) {
		return
	}
	for &u in users_buf[:user_count] {
		u.num = User_Num(get_u32(&r))
		u.account = Account_Id(get_u32(&r))
		u.flags = transmute(User_Flags)get_u8(&r)
		u.room = Room(get_u32(&r))
	}
	if r.overflow || r.pos != len(body) {
		return
	}
	state.users = users_buf[:user_count]
	return state, true
}

// find_user returns the user with number `num` in a snapshot, or nil.
find_user :: proc(state: ^Presence, num: User_Num) -> ^User_Info {
	for &u in state.users {
		if u.num == num {
			return &u
		}
	}
	return nil
}

// state_chunk_count returns the number of State messages that a snapshot body needs.
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

// state_message_version returns the snapshot version that a State message belongs to.
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

// assembler_add adds a State message. When it completes a snapshot, it returns
// the body, which stays valid until the next call.
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
	// Nothing to do if it is older than what the caller already has.
	if min_version != 0 && !serial_newer(version, min_version) {
		return
	}

	if a.count == 0 || serial_newer(version, a.version) {
		a.version, a.count, a.received, a.size = version, count, 0, 0
		a.have = {}
	} else if version != a.version || count != a.count {
		return // an older version, or one that is inconsistent with what we have
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
	a.count = 0 // start over for the next version
	return version, a.buf[:a.size], true
}
