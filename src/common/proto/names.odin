package proto

import "core:encoding/endian"
import "core:strings"
import "core:unicode/utf8"

/*
Display names: what an account is called (accounts.odin). They come from
clients, so the server runs them through sanitize_name before storing
one.

Display names aren't unique; an account's username is. Clients show the
username next to a name that appears more than once.
*/

MAX_NAME_SIZE :: 32 // bytes of UTF-8

// sanitize_name returns `name` as valid UTF-8 without control or invisible
// formatting characters (which could hide or reorder text), with
// surrounding whitespace trimmed and at most MAX_NAME_SIZE bytes, cut on a
// character boundary. The result points into `buf`.
sanitize_name :: proc(name: string, buf: ^[MAX_NAME_SIZE]u8) -> string {
	return sanitize_text(name, buf[:])
}

// sanitize_text is sanitize_name for any text and limit (len(buf)); used
// for chat messages too. Tabs and newlines become spaces.
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

// Zero-width characters, bidirectional controls and the BOM: they'd let a
// name look like another one, or rearrange the text around it.
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

/*
Hello: the encrypted payload of Handshake_Finish (msg3), which says
which of the client's connections this is, and carries the server
password if the server asks for one.

	[version u8 = 10][conn_id u64][password_len u8][password]

The version is what keeps a client and a server that disagree about the
wire format from talking past each other: the server refuses a hello it
can't read (see Refused in messages.odin) instead of leaving one side to
misread the other's messages.
Version 2 added the sound flags to a snapshot's users (see messages.odin).
Version 3 widened a chat entry's time to 64 bits (see chat.odin).
Version 4 added the password, and Refused.
Version 5 added conn_id, and Welcome.
Version 6 took the name out: it's the account's now (accounts.odin), and
with it the names left the snapshot's users, which say their account
instead.
Version 7 took the channels out of the snapshot, whose users now say
which voice room they're in (convs.odin), and retired Join.
Version 8 retired the chat and image kinds for messages kept by the
server (msgs.odin), and Typing names a conversation.
Version 9 retired the direct message and last-seen kinds (DMs are
conversations now), took the device's key out of the snapshot's users,
and has file transfers name accounts (files.odin).
Version 10 added attachments: a message's files (msgs.odin), and the
datagrams that move them (transfer.odin, attachments.odin).

`conn_id` is a random number the client picks when it opens a
connection and sends in every handshake of it. A client handshakes again
every so often to rekey, and the server has to tell that from a client
that started over, since a connection has state (the reliable stream,
stream.odin) that a rekey must keep and a new start must not. The same
`conn_id` as the connection it has for that client is a rekey; any other
is a client starting over, and the old connection goes as if it had left.

Welcome is the server's answer to a hello it accepts, the first Data on
the new session:

	server -> client  Welcome  [kind][instance u64][flags u8]

`instance` is a random number the server gives each connection when it
makes it. A client that gets the one it already has carries on: it has
rekeyed. Another one (or its first) means the connection is new on the
server's side - this client just started, or the server did, or it had
given up on us - so the client starts over too, forgetting what that
connection's state was. WELCOME_LOGGED_IN in `flags` says the server
knows this device and has logged it in to its account; without it the
client has to log in (accounts.odin) before it can do anything else.

It's unreliable like Refused, so the server sends a few copies, and
again whenever the client repeats its Handshake_Finish. Until it comes,
a client takes nothing else on a new session.
*/
HELLO_VERSION :: 10
MAX_PASSWORD_SIZE :: 64 // bytes
HELLO_MAX_SIZE :: 1 + 8 + 1 + MAX_PASSWORD_SIZE
WELCOME_SIZE :: 1 + 8 + 1

// Welcome flags.
WELCOME_LOGGED_IN :: 1 << 0

// encode_hello writes a hello. A password longer than MAX_PASSWORD_SIZE
// is cut short (and so won't match).
encode_hello :: proc(out: ^[HELLO_MAX_SIZE]u8, conn_id: u64, password := "") -> []u8 {
	p := min(len(password), MAX_PASSWORD_SIZE)
	out[0] = HELLO_VERSION
	endian.unchecked_put_u64le(out[1:], conn_id)
	out[9] = u8(p)
	copy(out[10:], password[:p])
	return out[:10 + p]
}

// decode_hello reads a hello; the password is as sent.
decode_hello :: proc(payload: []u8) -> (conn_id: u64, password: string, ok: bool) {
	if len(payload) < 10 || payload[0] != HELLO_VERSION {
		return
	}
	password_len := int(payload[9])
	if len(payload) != 10 + password_len {
		return
	}
	conn_id = endian.unchecked_get_u64le(payload[1:])
	password = string(payload[10:][:password_len])
	return conn_id, password, true
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
