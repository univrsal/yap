package proto

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

/*
Emoji, as both sides know them.

Unicode emoji are characters in the text, from the table in
emoji_table.odin (scripts/emoji.py makes it): one character each, with
shortcodes such as `smile` that the client offers when `:smi` is typed.
Sequences of several characters (flags, skin tones, people joined with
U+200D) aren't in it; sanitize_text drops the joiners and selectors, so
what's left of one is its parts.

A server's own emoji are `:name:` in the text, a name being 2 to 32 of
`a-z 0-9 _` (custom_emoji_name_ok). The server makes them from a folder
of pictures and tells its clients which there are (Emoji_Sheet): one
picture holding all of them, in cells of `cell` pixels, and their names
in the order of the cells.

	Emoji_Sheet  [blob u64][size u32][cell u16][count u16][name str8]...

A `:name:` that isn't one of the server's emoji is just text.
*/

Emoji :: struct {
	r:        rune,
	names:    string, // shortcodes, separated by spaces; the first is its name
	category: Emoji_Category,
}

Emoji_Ref :: struct {
	r:     rune,
	index: u16, // in EMOJI
}

// What a client puts in the text it shows where one of the server's
// emoji goes: one character, as wide as an emoji, drawn as nothing by
// the font, with the emoji's picture over it. Nobody may send it
// (sanitize_text drops it).
CUSTOM_EMOJI_PLACEHOLDER :: rune(0xE000)

// How a sheet lays its cells out: this many to a row, in name order.
EMOJI_SHEET_COLUMNS :: 16

MIN_EMOJI_NAME :: 2
MAX_EMOJI_NAME :: 32
// How many emoji a server may have of its own.
MAX_CUSTOM_EMOJI :: 512

// emoji_index is where a character is in EMOJI, if it's an emoji.
emoji_index :: proc(r: rune) -> (index: int, ok: bool) {
	i, found := slice.binary_search_by(EMOJI_BY_RUNE[:], r, proc(e: Emoji_Ref, r: rune) -> slice.Ordering {
		return slice.cmp(e.r, r)
	})
	if !found {
		return
	}
	return int(EMOJI_BY_RUNE[i].index), true
}

// emoji_name is an emoji's name: its first shortcode.
emoji_name :: proc(e: Emoji) -> string {
	if i := strings.index_byte(e.names, ' '); i >= 0 {
		return e.names[:i]
	}
	return e.names
}

// emoji_by_shortcode is the emoji one of whose shortcodes is `name`.
emoji_by_shortcode :: proc(name: string) -> (r: rune, ok: bool) {
	for e in EMOJI {
		names := e.names
		for code in strings.split_iterator(&names, " ") {
			if code == name {
				return e.r, true
			}
		}
	}
	return
}

// custom_emoji_name_ok is whether `name` may be a server's emoji's.
custom_emoji_name_ok :: proc(name: string) -> bool {
	if len(name) < MIN_EMOJI_NAME || len(name) > MAX_EMOJI_NAME {
		return false
	}
	for ch in transmute([]u8)name {
		switch ch {
		case 'a' ..= 'z', '0' ..= '9', '_':
		case:
			return false
		}
	}
	return true
}

// is_emoji is whether `text` is exactly one emoji: a character from the
// table, or a `:name:` (which may or may not be one of the server's;
// that's for whoever knows them to say).
is_emoji :: proc(text: string) -> bool {
	if len(text) > 2 && text[0] == ':' && text[len(text) - 1] == ':' {
		return custom_emoji_name_ok(text[1:len(text) - 1])
	}
	r, size := utf8.decode_rune_in_string(text)
	if size != len(text) || r == utf8.RUNE_ERROR {
		return false
	}
	_, ok := emoji_index(r)
	return ok
}

Emoji_Sheet :: struct {
	blob:  Blob_Id, // 0 for none: the server has no emoji of its own
	size:  int, // the blob's, in bytes
	cell:  int, // pixels
	names: []string,
}

encode_emoji_sheet :: proc(out: []u8, sheet: Emoji_Sheet) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u64(&w, u64(sheet.blob))
	put_u32(&w, u32(sheet.size))
	put_u16(&w, u16(sheet.cell))
	put_u16(&w, u16(len(sheet.names)))
	for n in sheet.names {
		put_str8(&w, n)
	}
	return nil if w.overflow else out[:w.pos]
}

// decode_emoji_sheet reads one; its names are in the temp allocator and
// point into `body`.
decode_emoji_sheet :: proc(body: []u8) -> (sheet: Emoji_Sheet, ok: bool) {
	r := Reader {
		buf = body,
	}
	sheet.blob = Blob_Id(get_u64(&r))
	sheet.size = int(get_u32(&r))
	sheet.cell = int(get_u16(&r))
	count := int(get_u16(&r))
	if r.overflow || count > MAX_CUSTOM_EMOJI {
		return
	}
	names := make([]string, count, context.temp_allocator)
	for &n in names {
		n = get_str8(&r)
	}
	if r.overflow {
		return
	}
	sheet.names = names
	return sheet, true
}
