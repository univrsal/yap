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
	// The lookup table is in order, and every emoji is in it once.
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
	sheet, sheet_ok := decode_emoji_sheet(encode_emoji_sheet(buf[:], {blob = 7, size = 900, cell = 32, names = names}))
	testing.expect(t, sheet_ok)
	testing.expect_value(t, sheet.blob, Blob_Id(7))
	testing.expect_value(t, sheet.size, 900)
	testing.expect_value(t, sheet.cell, 32)
	testing.expect_value(t, len(sheet.names), 2)
	if len(sheet.names) == 2 {
		testing.expect_value(t, sheet.names[1], "bar_2")
	}
}
