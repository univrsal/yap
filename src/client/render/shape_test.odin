#+build !wasi
package render

import "core:log"
import "core:testing"

// A font with the system's fonts on, for shaping.
@(private = "file")
shaping_font :: proc(t: ^testing.T, f: ^Font, s: ^System_Fonts) {
	testing.expect(t, font_init(f))
	f.sys = s
	system_fonts_enable(s, true)
}

// x_of returns where the glyph drawn for character `at` is (the first one).
@(private = "file")
x_of :: proc(sh: Shaped, at: int) -> f32 {
	for g in sh.glyphs {
		if g.at == at {
			return g.x
		}
	}
	return -1
}

@(test)
test_needs_shaping :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	for text in ([]string{"Hello, world!", "Привет, Ελληνικά", "中文 日本語 한국어", "😀 ❤️ ★ → ½"}) {
		testing.expectf(t, !needs_shaping(&f, text), "%q needs no shaping", text)
	}
	for text in ([]string{"שלום", "مرحبا", "नमस्ते", "ไทย", "é", "a‍b"}) {
		testing.expectf(t, needs_shaping(&f, text), "%q needs shaping", text)
	}
	// Not without the system's fonts' state (a font of its own, as in tests).
	plain: Font
	testing.expect(t, font_init(&plain))
	defer font_destroy(&plain)
	testing.expect(t, !needs_shaping(&plain, "שלום"))
}

// Right-to-left text is put in visual order, whatever font draws it
// (Unifont's letters are reordered too).
@(test)
test_shaping_order :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	// A left-to-right line with a Hebrew word: the word's first letter (4)
	// is right of its last (7), and the word sits between "abc" and "def".
	text := "abc שלום def"
	sh := shaped_text(&f, .Regular, text, false)
	testing.expect(t, x_of(sh, 4) > x_of(sh, 7))
	testing.expect(t, x_of(sh, 7) > x_of(sh, 2))
	testing.expect(t, x_of(sh, 9) > x_of(sh, 4))
	testing.expect_value(t, font_text_width(&f, text), sh.width)

	// Numbers after a Hebrew word go with it, on its left, and still read
	// left to right.
	sh = shaped_text(&f, .Regular, "abc שלום 123", false)
	testing.expect(t, x_of(sh, 9) < x_of(sh, 4))
	testing.expect(t, x_of(sh, 9) > x_of(sh, 2))
	testing.expect(t, x_of(sh, 10) > x_of(sh, 9))
	// But not after a Latin word.
	sh = shaped_text(&f, .Regular, "שלום abc 123", false)
	testing.expect(t, x_of(sh, 9) > x_of(sh, 7))

	// A right-to-left line: "abc" at the end is on the left, before the
	// Hebrew, which reads from the right.
	sh = shaped_text(&f, .Regular, "שלום abc", false)
	testing.expect(t, x_of(sh, 5) < x_of(sh, 3))
	testing.expect(t, x_of(sh, 0) > x_of(sh, 3))

	// In logical order (the composer), everything goes left to right as it
	// was typed.
	sh = shaped_text(&f, .Regular, text, true)
	for i in 1 ..< 12 {
		testing.expect(t, x_of(sh, i) > x_of(sh, i - 1))
	}
	testing.expect_value(t, font_text_width(&f, text, .Regular, true), sh.width)

	// The same width whatever the order.
	testing.expect(t, abs(shaped_text(&f, .Regular, text, true).width - shaped_text(&f, .Regular, text, false).width) < 0.01)
}

// Arabic letters join: the same letter has another form in the middle of a
// word than on its own. Only where the system has a font for Arabic.
@(test)
test_shaping_joins :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	arabic, has := system_glyph(&s, 'ب')
	if !has {
		log.info("no system font for Arabic")
		return
	}
	log.infof("ب is from %s", s.fonts[arabic.font].name)
	alone := shaped_text(&f, .Regular, "ب", false)
	word := shaped_text(&f, .Regular, "ببب", false)
	testing.expect(t, len(alone.glyphs) >= 1)
	testing.expect_value(t, alone.glyphs[0].kind, Shaped_Kind.Glyph)
	// The letters' forms in the word (a font may draw a letter as more than
	// one glyph: its body and its dot): the middle letter's isn't the
	// isolated one's, and the first, on the right, is another again.
	ids :: proc(sh: Shaped, at: int) -> (set: [dynamic]u16) {
		set = make([dynamic]u16, context.temp_allocator)
		for g in sh.glyphs {
			if g.at == at {
				append(&set, g.id)
			}
		}
		return
	}
	same :: proc(a, b: [dynamic]u16) -> bool {
		if len(a) != len(b) {
			return false
		}
		for v, i in a {
			if v != b[i] {
				return false
			}
		}
		return true
	}
	testing.expect(t, !same(ids(word, 1), ids(alone, 0)))
	testing.expect(t, !same(ids(word, 0), ids(alone, 0)) && !same(ids(word, 0), ids(word, 1)))
	testing.expect(t, x_of(word, 0) > x_of(word, 1))
	middle: Shaped_Glyph
	for g in word.glyphs {
		if g.at == 1 {
			middle = g
		}
	}

	// Glyphs go into the fallback atlas by font and glyph.
	glyph_atlas_reset(&f.fallback, 2)
	g, ok := shaped_glyph_cache(&f, middle.font, middle.id)
	testing.expect(t, ok && g.w > 0 && g.h > 0)
	again, _ := glyph_atlas_find(&f.fallback, shaped_key(middle.font, middle.id))
	testing.expect_value(t, again, g)
}

// Marks combine with the letter before them, in its font.
@(test)
test_shaping_marks :: proc(t: ^testing.T) {
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	// e with a combining acute: Roboto has both and composes or places them;
	// either way the pair is no wider than e and é side by side would be.
	sh := shaped_text(&f, .Regular, "é", false)
	testing.expect(t, len(sh.glyphs) >= 1)
	testing.expect(t, sh.width <= font_text_width(&f, "e") * 1.5)
	// A joiner takes no room.
	testing.expect(t, abs(shaped_text(&f, .Regular, "a‍b", false).width - font_text_width(&f, "ab")) < 0.5)
}
