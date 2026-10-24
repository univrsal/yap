package proto

import "core:encoding/endian"
import "core:strings"
import "core:unicode/utf8"

// Display names are the names accounts are shown with (see accounts.odin).
// They come from clients, so the server runs them through sanitize_name
// before storing them.
//
// Display names are not unique, but usernames are. Clients show the
// username next to a display name that appears more than once.

MAX_NAME_SIZE :: 32 // bytes of UTF-8

// sanitize_name returns `name` as valid UTF-8 without control characters or
// invisible formatting characters (which could hide or reorder text).
// Surrounding whitespace is trimmed and the result is cut to at most
// MAX_NAME_SIZE bytes on a character boundary. The result points into `buf`.
sanitize_name :: proc(name: string, buf: ^[MAX_NAME_SIZE]u8) -> string {
	return sanitize_text(name, buf[:])
}

// sanitize_text is sanitize_name for any text and any limit (len(buf)).
// The result is a single line: tabs and newlines become spaces.
// Chat messages keep their lines, so they use sanitize_message instead.
sanitize_text :: proc(text: string, buf: []u8) -> string {
	n := 0
	for r in text {
		switch {
		case r == utf8.RUNE_ERROR:
			continue // invalid UTF-8
		case r < 0x20, r == 0x7f, r >= 0x80 && r < 0xa0:
			if r == '\t' || r == '\n' || r == '\r' {
				// Whitespace becomes a space; other control characters go.
				if n < len(buf) {
					buf[n] = ' '
					n += 1
				}
			}
			continue
		case invisible(r), r == CUSTOM_EMOJI_PLACEHOLDER:
			continue
		}
		bytes, w := utf8.encode_rune(r)
		if n + w > len(buf) {
			break
		}
		copy(buf[n:], bytes[:w])
		n += w
	}
	return strings.trim_space(string(buf[:n]))
}

// The maximum number of consecutive blank lines a message keeps.
MAX_BLANK_LINES :: 2

// sanitize_message is sanitize_text for a chat message, which may have
// several lines. Newlines are kept: `\r\n`, a lone `\r` and the Unicode line
// and paragraph separators all become `\n`. Each line loses its trailing
// whitespace but keeps its indentation. Blank lines at the start and end
// are removed, and more than MAX_BLANK_LINES consecutive blank lines are
// shortened to MAX_BLANK_LINES. Whitespace before the first line's text is
// removed as well, like in sanitize_text.
sanitize_message :: proc(text: string, buf: []u8) -> string {
	n := 0
	// Counted but not written until a visible character follows, so that
	// trailing whitespace and trailing blank lines are dropped.
	newlines, spaces := 0, 0
	after_cr := false
	for r in text {
		cr := after_cr
		after_cr = false
		switch {
		case r == utf8.RUNE_ERROR:
			continue // invalid UTF-8
		case r == '\n' && cr:
			continue // the second half of a \r\n
		case r == '\n', r == '\r', r == 0x2028, r == 0x2029:
			newlines += 1
			spaces = 0
			after_cr = r == '\r'
			continue
		case r == '\t', r == ' ':
			spaces += 1
			continue
		case r < 0x20, r == 0x7f, r >= 0x80 && r < 0xa0:
			continue // other control characters go
		case invisible(r), r == CUSTOM_EMOJI_PLACEHOLDER:
			continue
		}
		breaks := 0 if n == 0 else min(newlines, MAX_BLANK_LINES + 1)
		indent := spaces if n > 0 else 0
		bytes, w := utf8.encode_rune(r)
		if n + breaks + indent + w > len(buf) {
			break
		}
		for _ in 0 ..< breaks {
			buf[n] = '\n'
			n += 1
		}
		for _ in 0 ..< indent {
			buf[n] = ' '
			n += 1
		}
		copy(buf[n:], bytes[:w])
		n += w
		newlines, spaces = 0, 0
	}
	return string(buf[:n])
}

// Zero-width characters, bidirectional controls and the BOM. These could make
// a name look like another one or rearrange the text around it.
@(private = "file")
invisible :: proc(r: rune) -> bool {
	switch r {
	case 0x00AD,
	     0x200B ..=
	     0x200F,
	     0x202A ..=
	     0x202E,
	     0x2060 ..=
	     0x2064,
	     0x2066 ..=
	     0x2069,
	     0xFEFF:
		return true
	}
	return false
}

// Hello is the encrypted payload of Handshake_Finish (msg3). It says which
// of the client's connections this is and carries the server password if
// the server asks for one.
//
//	[version u8 = 12][conn_id u64][link u8][password_len u8][password]
//
// The version prevents a client and a server that disagree about the wire
// format from misreading each other's messages: the server refuses a hello
// it can't read (see Refused in messages.odin).
// Version 2 added the sound flags to a snapshot's users (see messages.odin).
// Version 3 widened a chat entry's time to 64 bits (chat entries were
// retired in version 8).
// Version 4 added the password, and Refused.
// Version 5 added conn_id, and Welcome.
// Version 6 removed the name from the hello because it belongs to the account
// now (accounts.odin). The snapshot's users no longer carry names and
// reference their account instead.
// Version 7 removed the channels from the snapshot. Its users now say which
// voice room they are in (convs.odin), and Join was retired.
// Version 8 retired the chat and image kinds for messages stored by the
// server (msgs.odin), and Typing now names a conversation.
// Version 9 retired the direct message and last-seen kinds (DMs are
// conversations now), removed the device's key from the snapshot's users,
// and made file transfers name accounts (files.odin).
// Version 10 added attachments, which are a message's files (msgs.odin), and
// the datagrams that carry them (transfer.odin, attachments.odin).
// Version 12 added `link`, which says which of the connection's two links the
// handshake is for (see Link below).
// Version 13 retired the picture kind of message and purging only pictures,
// because a picture in a message is an attachment (msgs.odin).
// Version 14 added the time of the newest message to a conversation's record,
// which a list of DMs from several servers is put in order by (convs.odin).
// Link.Media was added without a new version because it is only ever sent to
// a client by a server that names a media port in Server_Info, and only on
// that port.
//
// `conn_id` is a random number the client picks when it opens a connection
// and sends in every handshake of that connection. A client handshakes again
// every so often to rekey, and the server has to distinguish that from a
// client that started over: a connection has state (such as the reliable
// stream, see stream.odin) that must be kept on a rekey but discarded when
// the client starts over. A `conn_id` that matches the connection the server
// already has for that client is a rekey. Any other `conn_id` means the
// client started over, and the old connection is removed as if the client
// had left. The exception is a second client using the same key: if the old
// connection was heard from within the last couple of seconds at another
// address, it is still in use, and the new hello is refused with
// Already_Connected instead.
//
// Each connection has two links. Each link has its own transport (a UDP
// socket, or a WebSocket on the web) and its own sessions, so that light
// traffic never queues behind heavy traffic:
//
//	Main  voice, pings, the reliable stream, snapshots, typing, watch
//	      leases and keyframe requests, i.e. everything small and urgent
//	Bulk  video fragments, and the chunks of blobs, attachments and
//	      file transfers (HEAVY_KINDS)
//
// A desktop client that shares or watches screens with the yap_video
// library has a third link on its own port (Server_Info's media_port),
// which is served by a separate server thread (server/media.odin):
//
//	Media video fragments, Watch leases and Keyframe requests, nothing
//	      else. Once it is up, video and leases use it instead of the
//	      bulk link (leases are also sent on the main link for sharers
//	      that are on bulk links)
//
// The main link is the connection itself: its hello's conn_id creates or
// continues the connection, and the server times it out. The bulk link joins
// a connection that the main link has already created. It does so with a
// hello that has the same conn_id and link = Bulk, sent through a handshake
// of its own with the same device key. The server binds it to that
// connection, or refuses it with No_Connection so the client can try again
// later. The bulk link is removed when its connection is. Until it is
// established, heavy messages go over the main link.
//
// Welcome is the server's answer to a hello it accepts, the first Data on
// the new session:
//
//	server -> client  Welcome  [kind][instance u64][flags u8]
//
// `instance` is a random number the server gives each connection when it
// creates it. A client that receives the instance it already has simply
// continues, because it has rekeyed. A different instance (or the first one)
// means the connection is new on the server's side: the client just started,
// the server restarted, or the server had given up on the client. The client
// then starts over too and forgets the old connection's state.
// WELCOME_LOGGED_IN in `flags` says that the server knows this device and has
// logged it in to its account. Without it, the client has to log in
// (accounts.odin) before it can do anything else.
//
// Like Refused, it is unreliable, so the server sends a few copies and sends
// them again whenever the client repeats its Handshake_Finish. A client
// accepts nothing else on a new session until the Welcome arrives.
HELLO_VERSION :: 14
MAX_PASSWORD_SIZE :: 64 // bytes
HELLO_MAX_SIZE :: 1 + 8 + 1 + 1 + MAX_PASSWORD_SIZE

// Which of a connection's links a handshake is for.
Link :: enum u8 {
	Main  = 0,
	Bulk  = 1,
	Media = 2, // on the media port
}

// The message kinds that go over the bulk link once there is one.
HEAVY_KINDS :: bit_set[Message_Kind] {
	.Video,
	.Blob_Chunk,
	.Upload_Chunk,
	.Download_Chunk,
	.File_Chunk,
}

// is_heavy says whether a message goes over the bulk link.
is_heavy :: proc(msg: []u8) -> bool {
	return len(msg) > 0 && Message_Kind(msg[0]) in HEAVY_KINDS
}
WELCOME_SIZE :: 1 + 8 + 1

// Welcome flags.
WELCOME_LOGGED_IN :: 1 << 0

// encode_hello writes a hello. A password longer than MAX_PASSWORD_SIZE
// is truncated (and therefore won't match).
encode_hello :: proc(
	out: ^[HELLO_MAX_SIZE]u8,
	conn_id: u64,
	password := "",
	link := Link.Main,
) -> []u8 {
	p := min(len(password), MAX_PASSWORD_SIZE)
	out[0] = HELLO_VERSION
	endian.unchecked_put_u64le(out[1:], conn_id)
	out[9] = u8(link)
	out[10] = u8(p)
	copy(out[11:], password[:p])
	return out[:11 + p]
}

// decode_hello reads a hello. The password is returned unchanged.
decode_hello :: proc(payload: []u8) -> (conn_id: u64, password: string, link: Link, ok: bool) {
	if len(payload) < 11 || payload[0] != HELLO_VERSION || payload[9] > u8(max(Link)) {
		return
	}
	password_len := int(payload[10])
	if len(payload) != 11 + password_len {
		return
	}
	conn_id = endian.unchecked_get_u64le(payload[1:])
	link = Link(payload[9])
	password = string(payload[11:][:password_len])
	return conn_id, password, link, true
}

encode_welcome :: proc(out: ^[WELCOME_SIZE]u8, instance: u64, logged_in: bool) -> []u8 {
	out[0] = u8(Message_Kind.Welcome)
	endian.unchecked_put_u64le(out[1:], instance)
	out[9] = WELCOME_LOGGED_IN if logged_in else 0
	return out[:]
}

decode_welcome :: proc(pt: []u8) -> (instance: u64, logged_in: bool) {
	return endian.unchecked_get_u64le(pt[1:]), pt[9] & WELCOME_LOGGED_IN != 0
}
