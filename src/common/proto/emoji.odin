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
	             [animated u16]([index u16][frames blob u64][size u32])...

Some of them move (an animated WebP or GIF in the folder): those are
`animated`, each with the index of its cell (which shows its first
frame) and a blob of kind Emoji_Frames holding all its frames, cells of
the same size in a grid of `columns`, with how long each is shown:

	Emoji_Frames  ["YEMA"][count u8][columns u8][duration_ms u16]...[WebP]

The list of animated ones came later: a client from before stops reading
after the names (and shows every emoji still), and a sheet from a server
from before has none.

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
// How many frames an animated one keeps (more are thinned out).
MAX_EMOJI_FRAMES :: 64
EMOJI_FRAMES_MAGIC :: "YEMA"

// emoji_index is where a character is in EMOJI, if it's an emoji.
emoji_index :: proc(r: rune) -> (index: int, ok: bool) {
	i, found := slice.binary_search_by(
		EMOJI_BY_RUNE[:],
		r,
		proc(e: Emoji_Ref, r: rune) -> slice.Ordering {
			return slice.cmp(e.r, r)
		},
	)
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
	blob:     Blob_Id, // 0 for none: the server has no emoji of its own
	size:     int, // the blob's, in bytes
	cell:     int, // pixels
	names:    []string,
	// The ones that move, by the index of their cell.
	animated: []Emoji_Anim,
}

// One of the server's emoji that moves: the index of its cell, and the
// blob (of kind Emoji_Frames) with its frames, and how big that is.
Emoji_Anim :: struct {
	index: int,
	blob:  Blob_Id,
	size:  int,
}

// The most an Emoji_Sheet takes, for `names`, `animated` of them moving.
emoji_sheet_max_size :: proc(names, animated: int) -> int {
	return 8 + 4 + 2 + 2 + names * (1 + MAX_EMOJI_NAME) + 2 + animated * (2 + 8 + 4)
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
	put_u16(&w, u16(len(sheet.animated)))
	for a in sheet.animated {
		put_u16(&w, u16(a.index))
		put_u64(&w, u64(a.blob))
		put_u32(&w, u32(a.size))
	}
	return nil if w.overflow else out[:w.pos]
}

// decode_emoji_sheet reads one; its names are in the temp allocator and
// point into `body`, as is the list of animated ones.
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
	// From a server from before animated ones, the list isn't there.
	if r.pos == len(body) {
		return sheet, true
	}
	moving := int(get_u16(&r))
	if r.overflow || moving > count {
		return
	}
	animated := make([]Emoji_Anim, moving, context.temp_allocator)
	for &a in animated {
		a.index = int(get_u16(&r))
		a.blob = Blob_Id(get_u64(&r))
		a.size = int(get_u32(&r))
		if a.index >= count {
			return
		}
	}
	if r.overflow {
		return
	}
	sheet.animated = animated
	return sheet, true
}

// What an Emoji_Frames blob holds: how long each frame is shown, in
// milliseconds, how many columns the grid has, and the grid, a WebP.
Emoji_Frames :: struct {
	durations: []u16,
	columns:   int,
	image:     []u8,
}

// encode_emoji_frames makes an Emoji_Frames blob, in `allocator`.
encode_emoji_frames :: proc(
	f: Emoji_Frames,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	n := len(f.durations)
	if n == 0 || n > MAX_EMOJI_FRAMES || f.columns <= 0 || f.columns > n || len(f.image) == 0 {
		return
	}
	data = make([]u8, 4 + 1 + 1 + 2 * n + len(f.image), allocator)
	w := Writer {
		buf = data,
	}
	put_bytes(&w, transmute([]u8)string(EMOJI_FRAMES_MAGIC))
	put_u8(&w, u8(n))
	put_u8(&w, u8(f.columns))
	for d in f.durations {
		put_u16(&w, d)
	}
	put_bytes(&w, f.image)
	return data, !w.overflow
}

// decode_emoji_frames reads one; the durations are in the temp allocator
// and the image points into `data`.
decode_emoji_frames :: proc(data: []u8) -> (f: Emoji_Frames, ok: bool) {
	r := Reader {
		buf = data,
	}
	if string(get_bytes(&r, 4)) != EMOJI_FRAMES_MAGIC {
		return
	}
	n := int(get_u8(&r))
	f.columns = int(get_u8(&r))
	if r.overflow || n == 0 || n > MAX_EMOJI_FRAMES || f.columns <= 0 || f.columns > n {
		return
	}
	f.durations = make([]u16, n, context.temp_allocator)
	for &d in f.durations {
		d = get_u16(&r)
	}
	if r.overflow || r.pos == len(data) {
		return
	}
	f.image = data[r.pos:]
	return f, true
}
