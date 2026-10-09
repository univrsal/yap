#+build !wasi
package render

import "core:testing"

import "common:proto"

@(test)
test_emoji_glyphs :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)

	// The sheet has every emoji the table has (scripts/emoji.py makes
	// both), and no others, and in order, as the lookup needs.
	testing.expect_value(t, len(EMOJI_CELLS), len(proto.EMOJI))
	for e in proto.EMOJI {
		_, ok := emoji_cell(e.r)
		testing.expectf(t, ok, "no picture for %r", e.r)
	}
	for r, n in EMOJI_CELLS[1:] {
		testing.expect(t, EMOJI_CELLS[n] < r)
	}
	cell, grin := emoji_cell('😀')
	testing.expect(t, grin)
	u0, v0, u1, v1 := emoji_uv(cell)
	testing.expect(t, u0 >= 0 && v0 >= 0 && u1 <= 1 && v1 <= 1 && u1 > u0 && v1 > v0)

	// They take room like a wide character; text stays as it was.
	testing.expect_value(t, font_text_width(&f, "😀"), EMOJI_ADVANCE)
	testing.expect(
		t,
		abs(font_text_width(&f, "a😀b") - (font_text_width(&f, "ab") + EMOJI_ADVANCE)) < 0.01,
	)
	testing.expect_value(t, font_text_width(&f, ""), f32(CUSTOM_EMOJI_ADVANCE))

	// One quad of the sheet, whole pixels, in the line's box.
	Quads :: struct {
		n: int,
		q: Glyph_Quad,
	}
	got: Quads
	font_set_scale(&f, 2)
	font_layout(&f, "😀", 0, 0, &got, proc(data: rawptr, q: Glyph_Quad) {
		g := (^Quads)(data)
		g.n += 1
		g.q = q
	})
	testing.expect_value(t, got.n, 1)
	testing.expect(t, got.q.emoji && !got.q.unifont)
	testing.expect_value(t, got.q.y1 - got.q.y0, EMOJI_SIZE)
	testing.expect(t, got.q.y0 >= 0 && got.q.y1 <= f32(LINE_HEIGHT))
	testing.expect(t, got.q.x0 >= 0 && got.q.x1 <= EMOJI_ADVANCE)
}
