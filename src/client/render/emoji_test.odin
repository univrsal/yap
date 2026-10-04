#+build !wasi
package render

import "core:testing"

import stbtt "client:wstbtt"
import "common:proto"

@(test)
test_emoji_glyphs :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)
	testing.expect(t, f.emoji_ok)

	// The font has every emoji the table has (scripts/emoji.py makes both).
	for e in proto.EMOJI {
		testing.expectf(t, stbtt.FindGlyphIndex(&f.emoji, e.r) != 0, "no glyph for %r", e.r)
	}
	// They take room like a wide character; text stays as it was.
	smile := font_text_width(&f, "😀")
	testing.expect(t, smile >= EMOJI_SIZE - 2 && smile <= EMOJI_SIZE + 4)
	testing.expect(
		t,
		abs(font_text_width(&f, "a😀b") - (font_text_width(&f, "ab") + smile)) < 0.01,
	)
	testing.expect_value(t, font_text_width(&f, "\uE000"), f32(CUSTOM_EMOJI_ADVANCE))

	// Drawn from the fallback atlas, at its scale.
	unifont_reset(&f.uni, 2)
	font_cache_glyphs(&f, "😀")
	testing.expect(t, '😀' in f.uni.slots)
	box := f.uni.emoji_boxes['😀']
	testing.expect(t, box.w > 20 && box.w <= f.uni.cell && box.h > 20 && box.h <= f.uni.cell)
}
