package proto

import "core:strings"
import "core:unicode/utf8"

// Display names are the names accounts are shown with (see accounts.odin).
// They come from clients, so the server runs them through sanitize_name
// before storing them.
//
// Display names are not unique, but usernames are. Clients show the
// username next to a display name that appears more than once.

// Bytes of UTF-8: a Mattermost first and last name (64 characters each) and
// the space between them, at up to 4 bytes per character.
MAX_NAME_SIZE :: 4 * (64 + 1 + 64)

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
