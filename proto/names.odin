package proto

import "core:strings"
import "core:unicode/utf8"

/*
Display names. They come from clients, so both ends run them through
sanitize_name: the server before storing or relaying one, and the client
before sending, so it can tell when the server has applied its name.

Names aren't unique and prove nothing; users are identified by their
public key. Clients show a key fingerprint next to names that appear
more than once.
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
		case invisible(r):
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
	case 0x00AD, 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x2064, 0x2066 ..= 0x2069, 0xFEFF:
		return true
	}
	return false
}

/*
Hello: the encrypted payload of Handshake_Finish (msg3), so the server
knows the client's name from the start. Room for more fields later, such
as a server password.

	[version u8 = 3][name_len u8][name]

An empty payload is a hello without a name.

The version is what keeps a client and a server that disagree about the
wire format from talking past each other: a mismatch fails the
handshake instead of leaving one side to misread the other's messages.
Version 2 added the sound flags to a snapshot's users (see messages.odin).
Version 3 widened a chat entry's time to 64 bits (see chat.odin).
*/
HELLO_VERSION :: 3
HELLO_MAX_SIZE :: 2 + MAX_NAME_SIZE

// encode_hello expects an already sanitized name.
encode_hello :: proc(out: ^[HELLO_MAX_SIZE]u8, name: string) -> []u8 {
	n := min(len(name), MAX_NAME_SIZE)
	out[0] = HELLO_VERSION
	out[1] = u8(n)
	copy(out[2:], name[:n])
	return out[:2 + n]
}

// decode_hello returns the raw name from a hello; sanitize it before use.
decode_hello :: proc(payload: []u8) -> (name: string, ok: bool) {
	if len(payload) == 0 {
		return "", true
	}
	if len(payload) < 2 || payload[0] != HELLO_VERSION || len(payload) < 2 + int(payload[1]) {
		return "", false
	}
	return string(payload[2:][:payload[1]]), true
}
