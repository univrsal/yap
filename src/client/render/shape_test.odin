#+build !wasi
package render

import "core:log"
import "core:math"
import "core:sync"
import "core:testing"

// kb_text_shape's state is global and one thread's (yap_shape.c), and
// destroying a System_Fonts shuts it down, so the tests that shape take turns.
@(private = "file")
shaping_lock: sync.Mutex

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
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	for text in ([]string{"Hello, world!", "Привет, Ελληνικά", "中文 日本語 한국어", "😀 ❤️ ★ → ½"}) {
		testing.expectf(t, !needs_shaping(&f, text), "%q needs no shaping", text)
	}
	for text in ([]string{"שלום", "مرحبا", "नमस्ते", "ไทย", "e\u0301", "a\u200db"}) {
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
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	// A left-to-right line with a Hebrew word: the word's first letter (4)
	// is right of its last (7), and the word sits between "abc" and "def".
	text := "abc שלום def"
	sh := shaped_text(&f, .Regular, text)
	testing.expect(t, x_of(sh, 4) > x_of(sh, 7))
	testing.expect(t, x_of(sh, 7) > x_of(sh, 2))
	testing.expect(t, x_of(sh, 9) > x_of(sh, 4))
	testing.expect_value(t, font_text_width(&f, text), sh.width)

	// Numbers after a Hebrew word go with it, on its left, and still read
	// left to right.
	sh = shaped_text(&f, .Regular, "abc שלום 123")
	testing.expect(t, x_of(sh, 9) < x_of(sh, 4))
	testing.expect(t, x_of(sh, 9) > x_of(sh, 2))
	testing.expect(t, x_of(sh, 10) > x_of(sh, 9))
	// Punctuation after those numbers, at the end of the line, belongs to
	// the line: the closing quote is at the far right, not with "123".
	sh = shaped_text(&f, .Regular, `"abc שלום 123"`)
	testing.expect(t, x_of(sh, 13) > x_of(sh, 5))
	testing.expect(t, x_of(sh, 10) < x_of(sh, 5))
	testing.expect(t, x_of(sh, 12) < x_of(sh, 5))

	// But not after a Latin word.
	sh = shaped_text(&f, .Regular, "שלום abc 123")
	testing.expect(t, x_of(sh, 9) > x_of(sh, 7))

	// A right-to-left line: "abc" at the end is on the left, before the
	// Hebrew, which reads from the right.
	sh = shaped_text(&f, .Regular, "שלום abc")
	testing.expect(t, x_of(sh, 5) < x_of(sh, 3))
	testing.expect(t, x_of(sh, 0) > x_of(sh, 3))
}

// Arabic letters join: the same letter has another form in the middle of a
// word than on its own. Only where the system has a font for Arabic.
@(test)
test_shaping_joins :: proc(t: ^testing.T) {
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
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
	alone := shaped_text(&f, .Regular, "ب")
	word := shaped_text(&f, .Regular, "ببب")
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
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	// e with a combining acute: Roboto has both and composes or places them;
	// either way the pair is no wider than e and é side by side would be.
	sh := shaped_text(&f, .Regular, "e\u0301")
	testing.expect(t, len(sh.glyphs) >= 1)
	testing.expect(t, sh.width <= font_text_width(&f, "e") * 1.5)
	// A joiner takes no room.
	testing.expect(t, abs(shaped_text(&f, .Regular, "a\u200db").width - font_text_width(&f, "ab")) < 0.5)
}

// The caret steps over a cluster whole: a mark continues its letter's
// grapheme, a letter after a letter starts a new one.
@(test)
test_shaping_graphemes :: proc(t: ^testing.T) {
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	sh := shaped_text(&f, .Regular, "e\xcc\x81x")
	testing.expect_value(t, len(sh.joined), 3)
	if len(sh.joined) == 3 {
		testing.expect(t, !sh.joined[0])
		testing.expect(t, sh.joined[1])
		testing.expect(t, !sh.joined[2])
	}
	// A Devanagari conjunct (ka, virama, ssa) is one grapheme.
	conj := shaped_text(&f, .Regular, "क्ष")
	testing.expect_value(t, len(conj.joined), 3)
	if len(conj.joined) == 3 {
		testing.expect(t, !conj.joined[0] && conj.joined[1] && conj.joined[2])
	}
}

// Typing a letter on the left of right-to-left text leaves the letters
// already there where they are, when the line is kept against the same
// right edge: they are placed from the right end, not rounded from the
// start of a line whose width has just changed.
@(test)
test_rtl_layout_from_right :: proc(t: ^testing.T) {
	sync.mutex_lock(&shaping_lock)
	defer sync.mutex_unlock(&shaping_lock)
	s: System_Fonts
	defer system_fonts_destroy(&s)
	f: Font
	shaping_font(t, &f, &s)
	defer font_destroy(&f)

	if _, has := system_glyph(&s, 'ש'); !has {
		log.info("no system font for Hebrew")
		return
	}
	for scale in ([?]f32{1, 1.5, 1.25}) {
		font_set_scale(&f, scale)
		glyph_atlas_reset(&f.fallback, scale)
		Quads :: struct {
			x: [dynamic]f32,
		}
		layout :: proc(f: ^Font, text: string, right: f32) -> [dynamic]f32 {
			q: Quads
			q.x = make([dynamic]f32, context.temp_allocator)
			font_cache_glyphs(f, text)
			x := right - math.ceil(font_text_width(f, text))
			font_layout(f, text, x, 0, &q, proc(data: rawptr, g: Glyph_Quad) {
				q := (^Quads)(data)
				append(&q.x, g.x1)
			})
			return q.x
		}
		for right in ([?]f32{300, 301, 333}) {
			short := layout(&f, "שלום", right)
			long := layout(&f, "שלוםא", right)
			testing.expect(t, len(short) > 0 && len(long) > len(short))
			// The letters of the short line are the last ones of the long.
			for v, i in short {
				j := len(long) - len(short) + i
				if j >= 0 && j < len(long) {
					testing.expectf(t, v == long[j], "scale %v right %v glyph %d: %v vs %v", scale, right, i, v, long[j])
				}
			}
		}
	}
}
