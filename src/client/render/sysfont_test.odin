#+build !wasi
package render

import "core:log"
import "core:testing"

@(test)
test_glyph_atlas_shelves :: proc(t: ^testing.T) {
	a: Glyph_Atlas
	defer glyph_atlas_destroy(&a)
	glyph_atlas_reset(&a, 1)
	testing.expect_value(t, a.side, 1024) // room for 32 rows of 17 pixels

	// Glyphs of about one height share a shelf, left to right; a much
	// shorter one starts its own.
	g1, _, ok1 := glyph_atlas_add(&a, 'a', 10, 16, 0, -12)
	g2, _, ok2 := glyph_atlas_add(&a, 'b', 12, 15, 0, -12)
	g3, _, ok3 := glyph_atlas_add(&a, '.', 3, 3, 0, -3)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, g2.y, g1.y)
	testing.expect(t, g2.x >= g1.x + g1.w + 1)
	testing.expect(t, g3.y != g1.y)
	found, _ := glyph_atlas_find(&a, 'b')
	testing.expect_value(t, found, g2)

	// The white block is there once there are pixels.
	uv, white := glyph_atlas_white(&a)
	testing.expect(t, white)
	wx, wy := int(uv.x * f32(a.side)), int(uv.y * f32(a.side))
	testing.expect_value(t, a.pixels[wy * int(a.side) + wx], 255)

	// A blank glyph takes no room but is known.
	space, pixels, ok := glyph_atlas_add(&a, ' ', 0, 0, 0, 0)
	testing.expect(t, ok && pixels == nil && space.w == 0)

	// Filling it up: no two glyphs overlap, and then it is full.
	n := 0
	for r := rune(0x4e00); ; r += 1 {
		g, _, added := glyph_atlas_add(&a, r, 17, 17, 0, -14)
		if !added {
			break
		}
		testing.expect(t, g.x + g.w <= a.side && g.y + g.h <= a.side)
		n += 1
	}
	testing.expect(t, a.full)
	testing.expect(t, n > 2500)
	_, _, ok = glyph_atlas_add(&a, 'z', 1, 1, 0, 0)
	testing.expect(t, !ok)

	glyph_atlas_reset(&a, 2)
	testing.expect(t, !a.full && len(a.glyphs) == 0 && a.pixels == nil)
}

// This depends on the machine's fonts: where there is no font for Chinese
// (a bare Linux), it only checks that Unifont is used.
@(test)
test_system_fonts :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)
	f.sys = &s

	// Off, as without any.
	testing.expect_value(t, font_text_width(&f, "中"), 16)
	testing.expect_value(t, len(s.found), 0)

	testing.expect(t, system_fonts_enable(&s, true))
	testing.expect(t, !system_fonts_enable(&s, true))
	system_fonts_language(&s, "zh_CN.UTF-8")
	testing.expect_value(t, s.language, "zh-cn")

	// What Roboto has is never asked about.
	font_text_width(&f, "Hello, мир")
	testing.expect_value(t, len(s.found), 0)

	g, ok := system_glyph(&s, '中')
	if !ok {
		log.info("no system font for 中; Unifont is used")
		testing.expect_value(t, font_text_width(&f, "中"), 16)
		return
	}
	font := s.fonts[g.font]
	log.infof("中 is from %s (%s)", font.name, font.path)
	testing.expect(t, font.name != "")
	testing.expect_value(t, system_fonts_in_use(&s)[0], font.name)
	// A CJK character is about an em wide.
	testing.expect(t, g.advance > 0.8 && g.advance < 1.2)
	testing.expect_value(t, font_text_width(&f, "中"), g.advance * f.em)
	// Asked once.
	font_text_width(&f, "中中中")
	testing.expect_value(t, s.fonts[g.font].used, 1)

	// Its glyph, at twice the size, has ink and sits on the baseline.
	glyph_atlas_reset(&f.fallback, 2)
	cached, cached_ok := system_glyph_cache(&s, &f.fallback, '中', f.em)
	testing.expect(t, cached_ok)
	testing.expect(t, f32(cached.w) > f.em && f32(cached.h) > f.em)
	testing.expect(t, cached.yoff < 0 && cached.yoff + cached.h > 0)
	ink := 0
	for y in 0 ..< cached.h {
		for x in 0 ..< cached.w {
			ink += int(f.fallback.pixels[int(cached.y + y) * int(f.fallback.side) + int(cached.x + x)])
		}
	}
	testing.expect(t, ink > 0)

	// Off again: Unifont.
	testing.expect(t, system_fonts_enable(&s, false))
	testing.expect_value(t, font_text_width(&f, "中"), 16)
}
