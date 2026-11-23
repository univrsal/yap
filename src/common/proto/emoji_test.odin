#+build !wasi
package proto

import "core:testing"

@(test)
test_emoji_table :: proc(t: ^testing.T) {
	i, ok := emoji_index(0x1F600)
	testing.expect(t, ok)
	testing.expect_value(t, emoji_name(EMOJI[i]), "grinning")
	_, ok = emoji_index('a')
	testing.expect(t, !ok)
	r, found := emoji_by_shortcode("+1")
	testing.expect(t, found && r == 0x1F44D)
	_, found = emoji_by_shortcode("no_such_thing")
	testing.expect(t, !found)
	// The lookup table is sorted, and contains every emoji exactly once.
	testing.expect_value(t, len(EMOJI_BY_RUNE), len(EMOJI))
	for e, n in EMOJI_BY_RUNE[1:] {
		testing.expect(t, EMOJI_BY_RUNE[n].r < e.r)
	}

	testing.expect(t, is_emoji("😀"))
	testing.expect(t, is_emoji(":party_parrot:"))
	testing.expect(t, !is_emoji("😀😀"))
	testing.expect(t, !is_emoji("a"))
	testing.expect(t, !is_emoji(":Bad Name:"))
	testing.expect(t, custom_emoji_name_ok("ok_2"))
	testing.expect(t, !custom_emoji_name_ok("x"))
	testing.expect(t, !custom_emoji_name_ok("dash-ed"))

	names := []string{"foo", "bar_2"}
	buf: [64]u8
	sheet, sheet_ok := decode_emoji_sheet(
		encode_emoji_sheet(buf[:], {blob = 7, size = 900, cell = 32, names = names}),
	)
	testing.expect(t, sheet_ok)
	testing.expect_value(t, sheet.blob, Blob_Id(7))
	testing.expect_value(t, sheet.size, 900)
	testing.expect_value(t, sheet.cell, 32)
	testing.expect_value(t, len(sheet.names), 2)
	if len(sheet.names) == 2 {
		testing.expect_value(t, sheet.names[1], "bar_2")
	}
	testing.expect_value(t, len(sheet.animated), 0)
}

@(test)
test_emoji_sheet_animated :: proc(t: ^testing.T) {
	names := []string{"foo", "bar_2", "spin"}
	animated := []Emoji_Anim{{index = 2, blob = 9, size = 1234}}
	buf: [128]u8
	body := encode_emoji_sheet(
		buf[:],
		{blob = 7, size = 900, cell = 64, names = names, animated = animated},
	)
	testing.expect(t, len(body) <= emoji_sheet_max_size(len(names), len(animated)))
	sheet, ok := decode_emoji_sheet(body)
	testing.expect(t, ok)
	testing.expect_value(t, len(sheet.animated), 1)
	if len(sheet.animated) == 1 {
		testing.expect_value(t, sheet.animated[0], animated[0])
	}

	// A sheet from an older server has no animated list, so none of its
	// emoji are animated.
	plain := encode_emoji_sheet(buf[:], {blob = 7, size = 900, cell = 64, names = names})
	old, old_ok := decode_emoji_sheet(plain[:len(plain) - 4])
	testing.expect(t, old_ok)
	testing.expect_value(t, len(old.names), 3)
	testing.expect_value(t, len(old.animated), 0)

	// An animated index past the end of the names, or a truncated list, is
	// rejected.
	bad := encode_emoji_sheet(
		buf[:],
		{blob = 7, size = 900, cell = 64, names = names, animated = {{index = 3, blob = 9}}},
	)
	_, ok = decode_emoji_sheet(bad)
	testing.expect(t, !ok)
	_, ok = decode_emoji_sheet(body[:len(body) - 1])
	testing.expect(t, !ok)
}

@(test)
test_emoji_frames :: proc(t: ^testing.T) {
	image := []u8{'R', 'I', 'F', 'F', 1, 2, 3}
	data, ok := encode_emoji_frames({durations = {100, 40, 70}, columns = 2, image = image})
	defer delete(data)
	testing.expect(t, ok)
	f, read := decode_emoji_frames(data)
	testing.expect(t, read)
	testing.expect_value(t, f.columns, 2)
	testing.expect_value(t, len(f.durations), 3)
	if len(f.durations) == 3 {
		testing.expect_value(t, f.durations[1], 40)
	}
	testing.expect_value(t, string(f.image), string(image))

	_, read = decode_emoji_frames(data[:4 + 1 + 1 + 6]) // missing image data
	testing.expect(t, !read)
	data[0] = 'X'
	_, read = decode_emoji_frames(data)
	testing.expect(t, !read)
	_, ok = encode_emoji_frames({durations = {100}, columns = 2, image = image}) // too many columns
	testing.expect(t, !ok)
	_, ok = encode_emoji_frames(
		{
			durations = make([]u16, MAX_EMOJI_FRAMES + 1, context.temp_allocator),
			columns = 1,
			image = image,
		},
	)
	testing.expect(t, !ok)
}

@(test)
test_emoji_sheet_wide :: proc(t: ^testing.T) {
	names := []string{"a", "bb", "cc", "dd"}
	spans := []u8{1, 3, 1, 2}
	buf: [128]u8
	body := encode_emoji_sheet(
		buf[:],
		{blob = 7, size = 900, cell = 64, names = names, spans = spans},
	)
	testing.expect(t, len(body) <= emoji_sheet_max_size(len(names), 0))
	sheet, ok := decode_emoji_sheet(body)
	testing.expect(t, ok)
	testing.expect_value(t, string(sheet.spans), string(spans))

	// A sheet without wide emoji says so, and a sheet from a server that doesn't
	// know about them has none.
	square, square_ok := decode_emoji_sheet(
		encode_emoji_sheet(buf[:], {blob = 7, size = 900, cell = 64, names = names}),
	)
	testing.expect(t, square_ok)
	for i in 0 ..< len(names) {
		testing.expect_value(t, emoji_span(square.spans, i), 1)
	}
	plain := encode_emoji_sheet(buf[:], {blob = 7, names = names})
	older, older_ok := decode_emoji_sheet(plain[:len(plain) - 2])
	testing.expect(t, older_ok && len(older.spans) == 0)

	// A span that is out of range or at a name that isn't there is rejected.
	for bad in ([]Emoji_Pos{{1, 4}, {1, 1}, {1, 2}, {4, 2}}) {
		w := Writer {
			buf = buf[:],
		}
		put_u64(&w, 7)
		put_u32(&w, 0)
		put_u16(&w, 64)
		put_u16(&w, u16(len(names)))
		for n in names {
			put_str8(&w, n)
		}
		put_u16(&w, 0)
		put_u16(&w, 1)
		put_u16(&w, u16(bad.col))
		put_u8(&w, u8(bad.row))
		// (col is the index and row the span here.)
		_, ok = decode_emoji_sheet(written(&w))
		testing.expect_value(t, ok, bad.col < 4 && bad.row >= 2 && bad.row <= MAX_EMOJI_SPAN)
	}
}

@(test)
test_emoji_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, emoji_span_for(10, 10), 1)
	testing.expect_value(t, emoji_span_for(13, 10), 1)
	testing.expect_value(t, emoji_span_for(14, 10), 2)
	testing.expect_value(t, emoji_span_for(23, 10), 2)
	testing.expect_value(t, emoji_span_for(24, 10), 3)
	testing.expect_value(t, emoji_span_for(400, 20), 3)
	testing.expect_value(t, emoji_span_for(10, 20), 1)

	// Square emoji are placed in order.
	pos, rows := emoji_layout(nil, 5, 4)
	testing.expect_value(t, rows, 2)
	testing.expect_value(t, pos[3], Emoji_Pos{3, 0})
	testing.expect_value(t, pos[4], Emoji_Pos{0, 1})
	_, rows = emoji_layout(nil, 0, 4)
	testing.expect_value(t, rows, 0)

	// A wide one that doesn't fit in the rest of a row starts the next.
	pos, rows = emoji_layout({1, 1, 3, 2, 1}, 5, 4)
	testing.expect_value(t, rows, 3)
	testing.expect_value(t, pos[2], Emoji_Pos{0, 1})
	testing.expect_value(t, pos[3], Emoji_Pos{0, 2})
	testing.expect_value(t, pos[4], Emoji_Pos{2, 2})
	// One wider than a row is made to fit it.
	pos, rows = emoji_layout({3}, 1, 2)
	testing.expect_value(t, rows, 1)

	for span in 1 ..= MAX_EMOJI_SPAN {
		testing.expect_value(t, emoji_placeholder_span(emoji_placeholder(span)), span)
	}
	testing.expect_value(t, emoji_placeholder_span('a'), 0)
}
