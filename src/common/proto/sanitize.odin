package proto

import "core:strings"
import "core:unicode"
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

// Characters that show nothing (or only change how what is around them is
// shown): zero-width characters, bidirectional controls, the BOM, the
// default-ignorable fillers (Hangul and Braille blanks among them), the
// invisible operators and annotation marks, and the tag characters (which
// carry hidden text). They could make a name look like another one, or
// rearrange the text around it. Variation selectors aren't here: emoji need
// them.
@(private = "file")
invisible :: proc(r: rune) -> bool {
	switch r {
	case 0x00AD,
	     0x034F,
	     0x061C,
	     0x115F,
	     0x1160,
	     0x17B4,
	     0x17B5,
	     0x180B ..=
	     0x180F,
	     0x200B ..=
	     0x200F,
	     0x202A ..=
	     0x202E,
	     0x2060 ..=
	     0x206F,
	     0x2800,
	     0x3164,
	     0xFEFF,
	     0xFFA0,
	     0xFFF9 ..=
	     0xFFFB,
	     0xE0000 ..=
	     0xE007F:
		return true
	}
	return false
}

// name_skeleton reduces a name to what it looks like, so that two names that
// look alike are equal: invisible characters and variation selectors are
// dropped, letters are folded to lower case, full-width forms become
// ASCII, and letters that look like a Latin one (Cyrillic and Greek ones, and
// the likes of 0 and O, 1, l and I) become that one. It errs on the side of
// calling names alike: the cost of that is only that clients show the
// username next to the name.
name_skeleton :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for r in name {
		r := r
		switch {
		case invisible(r), r >= 0xFE00 && r <= 0xFE0F, r >= 0xE0100 && r <= 0xE01EF:
			continue
		case r >= 0xFF01 && r <= 0xFF5E:
			r -= 0xFEE0 // full-width ASCII
		}
		r = unicode.to_lower(r)
		switch r {
		case 'а', 'α':
			r = 'a'
		case 'ь', 'ъ':
			r = 'b'
		case 'с', 'ϲ':
			r = 'c'
		case 'ԁ':
			r = 'd'
		case 'е', 'ё', 'є':
			r = 'e'
		case 'һ':
			r = 'h'
		case 'і', 'ї', 'ι', 'ı', 'l', '1', '|':
			r = 'i'
		case 'ј':
			r = 'j'
		case 'к', 'κ':
			r = 'k'
		case 'м':
			r = 'm'
		case 'п', 'η':
			r = 'n'
		case 'о', 'ο', '0':
			r = 'o'
		case 'р', 'ρ':
			r = 'p'
		case 'ԛ':
			r = 'q'
		case 'ѕ', '5':
			r = 's'
		case 'т', 'τ':
			r = 't'
		case 'υ', 'ц':
			r = 'u'
		case 'ν':
			r = 'v'
		case 'ԝ':
			r = 'w'
		case 'х', 'χ':
			r = 'x'
		case 'у', 'γ':
			r = 'y'
		case 'з':
			r = 'z'
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// names_alike says whether two names look the same (see name_skeleton).
names_alike :: proc(a, b: string) -> bool {
	return name_skeleton(a) == name_skeleton(b)
}
