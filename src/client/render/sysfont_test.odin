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
	g1, _, ok1 := glyph_atlas_add(&a, atlas_key('a'), 10, 16, 0, -12)
	g2, _, ok2 := glyph_atlas_add(&a, atlas_key('b'), 12, 15, 0, -12)
	g3, _, ok3 := glyph_atlas_add(&a, atlas_key('.'), 3, 3, 0, -3)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, g2.y, g1.y)
	testing.expect(t, g2.x >= g1.x + g1.w + 1)
	testing.expect(t, g3.y != g1.y)
	found, _ := glyph_atlas_find(&a, atlas_key('b'))
	testing.expect_value(t, found, g2)

	// The white block is there once there are pixels.
	uv, white := glyph_atlas_white(&a)
	testing.expect(t, white)
	wx, wy := int(uv.x * f32(a.side)), int(uv.y * f32(a.side))
	testing.expect_value(t, a.pixels[wy * int(a.side) + wx], 255)

	// A blank glyph takes no room but is known.
	space, pixels, ok := glyph_atlas_add(&a, atlas_key(' '), 0, 0, 0, 0)
	testing.expect(t, ok && pixels == nil && space.w == 0)

	// Filling it up: no two glyphs overlap, and then it is full.
	n := 0
	for r := rune(0x4e00); ; r += 1 {
		g, _, added := glyph_atlas_add(&a, atlas_key(r), 17, 17, 0, -14)
		if !added {
			break
		}
		testing.expect(t, g.x + g.w <= a.side && g.y + g.h <= a.side)
		n += 1
	}
	testing.expect(t, a.full)
	testing.expect(t, n > 2500)
	_, _, ok = glyph_atlas_add(&a, atlas_key('z'), 1, 1, 0, 0)
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

// This depends on the machine's emoji font too: where there is none we can
// draw, it only checks that the sheet is used.
@(test)
test_system_emoji :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)

	// Off: none.
	_, on := system_emoji_glyph(&s, 0x1f600)
	testing.expect(t, !on)

	testing.expect(t, system_emoji_enable(&s, true))
	glyph, ok := system_emoji_glyph(&s, 0x1f600)
	if !ok {
		log.info("no system emoji font we can draw; the sheet is used")
		testing.expect_value(t, system_emoji_name(&s), "")
		return
	}
	log.infof("😀 is glyph %d of %s (%v)", glyph, system_emoji_name(&s), s.emoji.font.format)
	testing.expect(t, system_emoji_name(&s) != "")
	// Letters aren't emoji, even where the font has a glyph for them.
	_, letter := system_emoji_glyph(&s, 'a')
	testing.expect(t, !letter)

	// Drawn at 36 pixels (2x): in color in the middle, clear in the corners.
	a := Glyph_Atlas{rgba = true}
	defer glyph_atlas_destroy(&a)
	glyph_atlas_reset(&a, 2)
	g, drawn := system_emoji_cache(&s, &a, 0x1f600, 36, EMOJI_FILL)
	testing.expect(t, drawn)
	testing.expect_value(t, g.w, 36)
	testing.expect_value(t, g.h, 36)
	at :: proc(a: ^Glyph_Atlas, g: Atlas_Glyph, x, y: i32) -> [4]u8 {
		p := a.pixels[(int(g.y + y) * int(a.side) + int(g.x + x)) * 4:]
		return {p[0], p[1], p[2], p[3]}
	}
	testing.expect_value(t, at(&a, g, 0, 0)[3], 0)
	testing.expect_value(t, at(&a, g, 35, 35)[3], 0)
	colored := 0
	for y in i32(8) ..< 28 {
		for x in i32(8) ..< 28 {
			p := at(&a, g, x, y)
			if p[3] > 200 && abs(int(p[0]) - int(p[2])) > 60 {
				colored += 1
			}
		}
	}
	// A yellow face: most of the middle is opaque and far from gray.
	testing.expect(t, colored > 100)
	again, _ := system_emoji_cache(&s, &a, 0x1f600, 36, EMOJI_FILL)
	testing.expect_value(t, again, g)

	// Off again.
	testing.expect(t, system_emoji_enable(&s, false))
	_, on = system_emoji_glyph(&s, 0x1f600)
	testing.expect(t, !on)
}
