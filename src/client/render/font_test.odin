#+build !wasi
package render

import "core:testing"
import mu "vendor:microui"

@(test)
test_font_handles :: proc(t: ^testing.T) {
	// The handles that were there before styles keep their meaning.
	testing.expect_value(t, font_handle(.UI, .Regular), mu.Font(nil))
	testing.expect_value(t, font_handle(.Chat, .Regular), CHAT_FONT)
	for style in Font_Style {
		testing.expect_value(t, font_style(chat_font(style)), style)
		testing.expect_value(t, font_style(font_handle(.UI, style)), style)
	}
}

@(test)
test_font_faces :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)

	// Only Regular is read until another face is asked for.
	for style in Font_Style {
		testing.expect_value(t, f.faces[style].tried, style == .Regular)
	}
	text := "Hello, world"
	regular := font_text_width(&f, text)
	bold := font_text_width(&f, text, .Bold)
	italic := font_text_width(&f, text, .Italic)
	testing.expect(t, f.faces[.Bold].ok && f.faces[.Italic].ok)
	testing.expect(t, !f.faces[.Mono].tried)
	// The same em: close to Regular, but not the same.
	testing.expect(t, bold > regular && bold < regular * 1.15)
	testing.expect(t, italic != regular && italic > regular * 0.9 && italic < regular * 1.1)
	testing.expect(t, font_text_width(&f, text, .Bold_Italic) > 0)

	// Mono: every character as wide as the next.
	testing.expect_value(t, font_text_width(&f, "iii", .Mono), font_text_width(&f, "WWW", .Mono))
	testing.expect(t, font_text_width(&f, "iii", .Mono) > font_text_width(&f, "iii"))

	// Emoji and Unifont have no styles: as wide in any face.
	testing.expect_value(t, font_text_width(&f, "😀中", .Bold), font_text_width(&f, "😀中"))
	used := font_faces_used(&f, "a😀中", .Bold)
	testing.expect_value(t, used, bit_set[Font_Style]{.Bold})
}

@(test)
test_font_face_atlas :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)

	Count :: struct {
		quads: int,
		faces: bit_set[Font_Style],
	}
	count :: proc(f: ^Font, text: string, style: Font_Style) -> Count {
		c: Count
		font_layout(f, text, 0, 0, &c, proc(data: rawptr, q: Glyph_Quad) {
				c := (^Count)(data)
				c.quads += 1
				c.faces += {q.face}
			}, style)
		return c
	}

	font_set_scale(&f, 2)
	testing.expect(t, font_build_atlas(&f, .Regular))
	// Bold has no atlas yet: nothing of it is drawn.
	testing.expect_value(t, count(&f, "ab", .Bold).quads, 0)
	testing.expect(t, font_build_atlas(&f, .Bold))
	testing.expect(t, f.faces[.Bold].pixels != nil)
	// Built once per scale.
	testing.expect(t, !font_build_atlas(&f, .Bold))
	c := count(&f, "ab", .Bold)
	testing.expect_value(t, c.quads, 2)
	testing.expect_value(t, c.faces, bit_set[Font_Style]{.Bold})
	// Another scale, another atlas.
	font_set_scale(&f, 1.5)
	testing.expect_value(t, count(&f, "ab", .Bold).quads, 0)
	testing.expect(t, font_build_atlas(&f, .Bold))
	testing.expect(t, f.faces[.Bold].scale == 1.5)
}

// Text moved by whole logical pixels moves as a block: its glyphs keep
// their places relative to each other on the physical grid (at 1.5 they
// used to round one way or the other each on its own, and letters
// shuffled as a window was resized).
@(test)
test_text_moves_as_a_block :: proc(t: ^testing.T) {
	f: Font
	testing.expect(t, font_init(&f))
	defer font_destroy(&f)
	for scale in ([]f32{1.25, 1.5, 1.75}) {
		font_set_scale(&f, scale)
		testing.expect(t, font_build_atlas(&f, .Regular))
		first := glyph_lefts(&f, 0)
		testing.expect(t, len(first) > 10)
		for x in 1 ..< 12 {
			at := glyph_lefts(&f, f32(x))
			testing.expect_value(t, len(at), len(first))
			shift := at[0] - first[0]
			for i in 0 ..< min(len(at), len(first)) {
				testing.expectf(
					t,
					abs(at[i] - first[i] - shift) < 0.01,
					"scale %.2f, x %d: glyph %d moved %.1f, the first %.1f",
					scale,
					x,
					i,
					at[i] - first[i],
					shift,
				)
			}
		}
	}
}

// glyph_lefts is where each glyph of a line starts, laid out from `x`
// (physical pixels).
@(private = "file")
glyph_lefts :: proc(f: ^Font, x: f32) -> [dynamic]f32 {
	Placed :: struct {
		scale: f32,
		xs:    [dynamic]f32,
	}
	p := Placed {
		scale = f.scale,
		xs    = make([dynamic]f32, context.temp_allocator),
	}
	font_layout(f, "Connect wobbly letters", x, 0, &p, proc(data: rawptr, q: Glyph_Quad) {
		p := (^Placed)(data)
		append(&p.xs, q.x0 * p.scale)
	})
	return p.xs
}
