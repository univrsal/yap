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

	// At twice the size, every pixel of the chart becomes a 2 x 2 block.
	unifont_reset(&u, 2)
	slot, ok := unifont_cache(&u, '中')
	testing.expect(t, ok)
	testing.expect_value(t, slot, 0)
	testing.expect_value(t, unifont_glyph_width(&u, '中'), 32)
	at :: proc(u: ^Unifont, x, y: int) -> u8 {return u.pixels[y * int(u.side) + x]}
	testing.expect_value(t, at(&u, 13, 0), 0)
	testing.expect_value(t, at(&u, 14, 0), 255)
	testing.expect_value(t, at(&u, 15, 1), 255)
	testing.expect_value(t, at(&u, 16, 0), 0)
	testing.expect(t, u.dirty_y1 > u.dirty_y0)

	// The same character again does not take a new slot, but another
	// character does.
	slot, ok = unifont_cache(&u, '中')
	testing.expect_value(t, slot, 0)
	slot, ok = unifont_cache(&u, 'A')
	testing.expect_value(t, slot, 1)
	testing.expect_value(t, unifont_glyph_width(&u, 'A'), 16)

	// A fractional scale keeps the glyph's proportions.
	unifont_reset(&u, 1.5)
	testing.expect_value(t, len(u.slots), 0)
	testing.expect_value(t, unifont_glyph_height(1.5), 24)
	testing.expect_value(t, unifont_glyph_width(&u, '中'), 24)
	testing.expect_value(t, unifont_glyph_width(&u, 'A'), 12)

	// At a fractional scale every pixel of the chart takes the same room: the
	// glyph has as much ink as the chart's pixels times the scale squared,
	// with soft edges, rather than whole pixels of uneven widths.
	slot, ok = unifont_cache(&u, '中')
	testing.expect(t, ok)
	set := 0
	for row in u.rows[int('中') * 16:][:16] {
		for b in 0 ..< 16 {
			set += int(row >> uint(b)) & 1
		}
	}
	ink, soft := 0, 0
	for y in 0 ..< 24 {
		for x in 0 ..< 24 {
			v := at(&u, x, y)
			ink += int(v)
			soft += 1 if v != 0 && v != 255 else 0
		}
	}
	testing.expect(t, abs(f32(ink) / 255 - f32(set) * 2.25) < 1)
	testing.expect(t, soft > 0)

	// At a whole scale, nothing is soft.
	unifont_reset(&u, 2)
	slot, ok = unifont_cache(&u, '中')
	for y in 0 ..< 32 {
		for x in 0 ..< 32 {
			v := at(&u, x, y)
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
