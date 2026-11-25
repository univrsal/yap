#+build !wasi
package render

import "core:testing"

@(test)
test_unifont_chart :: proc(t: ^testing.T) {
	u: Unifont
	defer unifont_destroy(&u)

	testing.expect_value(t, unifont_width(&u, 'A'), 8)
	testing.expect_value(t, unifont_width(&u, '中'), 16)
	testing.expect_value(t, unifont_width(&u, 'あ'), 16)
	testing.expect_value(t, unifont_width(&u, 0x3000), 16) // blank but wide
	testing.expect_value(t, unifont_width(&u, 0x7f), 0) // control characters have boxes
	testing.expect_value(t, unifont_width(&u, 0x1f600), 0) // outside the chart
	testing.expect(t, u.loaded)

	// 'A': blank above, the apex is on row 4 and the crossbar on row 9.
	testing.expect_value(t, u.rows['A' * 16 + 3], 0)
	testing.expect_value(t, u.rows['A' * 16 + 4], 0b0001_1000_0000_0000)
	testing.expect_value(t, u.rows['A' * 16 + 9], 0b0111_1110_0000_0000)
	// '中': the vertical stroke down the middle is in column 7.
	testing.expect_value(t, u.rows['中' * 16 + 0], 0b0000_0001_0000_0000)
}


@(test)
test_unifont_cache_scales :: proc(t: ^testing.T) {
	u: Unifont
	defer unifont_destroy(&u)
	a: Glyph_Atlas
	defer glyph_atlas_destroy(&a)
	// The pixel at x, y of a glyph in the atlas.
	at :: proc(a: ^Glyph_Atlas, g: Atlas_Glyph, x, y: i32) -> u8 {
		return a.pixels[int(g.y + y) * int(a.side) + int(g.x + x)]
	}

	// At twice the size, every pixel of the chart becomes a 2 x 2 block.
	glyph_atlas_reset(&a, 2)
	g, ok := unifont_cache(&u, &a, '中')
	testing.expect(t, ok)
	testing.expect_value(t, g.w, 32)
	testing.expect_value(t, g.h, 32)
	testing.expect_value(t, g.yoff, -28) // its top is 14 pixels of the chart above the baseline
	testing.expect_value(t, at(&a, g, 13, 0), 0)
	testing.expect_value(t, at(&a, g, 14, 0), 255)
	testing.expect_value(t, at(&a, g, 15, 1), 255)
	testing.expect_value(t, at(&a, g, 16, 0), 0)
	testing.expect(t, a.dirty_y1 > a.dirty_y0)

	// The same character again is the same glyph, and another character
	// goes somewhere else.
	again, _ := unifont_cache(&u, &a, '中')
	testing.expect_value(t, again, g)
	letter, _ := unifont_cache(&u, &a, 'A')
	testing.expect(t, letter.x != g.x || letter.y != g.y)
	testing.expect_value(t, letter.w, 16)

	// A fractional scale keeps the glyph's proportions.
	glyph_atlas_reset(&a, 1.5)
	testing.expect_value(t, len(a.glyphs), 0)
	testing.expect_value(t, unifont_glyph_height(1.5), 24)
	testing.expect_value(t, unifont_glyph_width(&u, '中', 1.5), 24)
	testing.expect_value(t, unifont_glyph_width(&u, 'A', 1.5), 12)

	// At a fractional scale every pixel of the chart takes the same room: the
	// glyph has as much ink as the chart's pixels times the scale squared,
	// with soft edges, rather than whole pixels of uneven widths.
	g, ok = unifont_cache(&u, &a, '中')
	testing.expect(t, ok)
	set := 0
	for row in u.rows[int('中') * 16:][:16] {
		for b in 0 ..< 16 {
			set += int(row >> uint(b)) & 1
		}
	}
	ink, soft := 0, 0
	for y in 0 ..< i32(24) {
		for x in 0 ..< i32(24) {
			v := at(&a, g, x, y)
			ink += int(v)
			soft += 1 if v != 0 && v != 255 else 0
		}
	}
	testing.expect(t, abs(f32(ink) / 255 - f32(set) * 2.25) < 1)
	testing.expect(t, soft > 0)

	// At a whole scale, nothing is soft.
	glyph_atlas_reset(&a, 2)
	g, ok = unifont_cache(&u, &a, '中')
	for y in 0 ..< i32(32) {
		for x in 0 ..< i32(32) {
			v := at(&a, g, x, y)
			testing.expect(t, v == 0 || v == 255)
		}
	}
}

@(test)
test_font_falls_back_to_unifont :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)

	a := font_text_width(&f, "a")
	testing.expect_value(t, font_text_width(&f, "中文"), 32)
	testing.expect_value(t, font_text_width(&f, "a中"), a + 16)
	// A variation selector takes up no space of its own.
	testing.expect_value(t, font_text_width(&f, "中️"), 16)
}
