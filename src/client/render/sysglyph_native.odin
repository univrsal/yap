#+build !wasi
package render

import stbtt "client:wstbtt"
import "core:unicode"

// The system's fonts, found and drawn with stb_truetype (sysfont.odin).

// system_glyph_find asks the system which fonts have a character and takes
// the first that really draws it. For a script whose letters join or
// reorder, a font with OpenType's rules for that (a GSUB table) is taken
// first: some of macOS's fonts have only Apple's own kind (AAT), which
// kb_text_shape doesn't apply, so their letters would stay apart.
@(private)
system_glyph_find :: proc(s: ^System_Fonts, r: rune) -> System_Glyph {
	candidates := make([dynamic]Font_File, context.temp_allocator)
	system_font_candidates(s, r, &candidates)
	for pass in 0 ..< 2 {
		if pass == 0 && !needs_rules(r) {
			continue
		}
		for c in candidates {
			i := system_font_open(s, c)
			if i < 0 {
				continue
			}
			f := &s.fonts[i]
			if pass == 0 && !f.gsub {
				continue
			}
			if stbtt.FindGlyphIndex(&f.info, r) == 0 {
				continue
			}
			// Some fonts map characters to glyphs without outlines: an emoji
			// font's pictures, which stb_truetype can't draw, or a
			// placeholder. Those are left to the next font or to Unifont.
			// Spaces are blank anyway.
			if !unicode.is_space(r) {
				x0, y0, x1, y1: i32
				stbtt.GetCodepointBitmapBox(&f.info, r, 1, 1, &x0, &y0, &x1, &y1)
				if x1 <= x0 || y1 <= y0 {
					continue
				}
			}
			advance, lsb: i32
			stbtt.GetCodepointHMetrics(&f.info, r, &advance, &lsb)
			return {font = i32(i), advance = f32(advance) * f.per_em}
		}
	}
	return {font = -1}
}

// needs_rules returns whether a character is of a script whose letters join
// or are reordered (Arabic and its neighbors, the Indic scripts, Tibetan,
// Myanmar, Khmer, Mongolian and others), so that its font needs OpenType
// rules for it.
@(private = "file")
needs_rules :: proc(r: rune) -> bool {
	switch r {
	case 0x0600 ..=
	     0x08ff,
	     0x0900 ..=
	     0x0dff,
	     0x0f00 ..=
	     0x109f,
	     0x1780 ..=
	     0x18af,
	     0xa800 ..=
	     0xabff:
		return true
	}
	return false
}

// system_glyph_cache puts a character's glyph from a system font into the
// atlas `a` for a font of em size `em` (logical pixels), if it is not there
// already. It fails once the atlas is full (it is then emptied before the
// next frame).
system_glyph_cache :: proc(
	s: ^System_Fonts,
	a: ^Glyph_Atlas,
	r: rune,
	em: f32,
) -> (
	g: Atlas_Glyph,
	ok: bool,
) {
	if g, ok = glyph_atlas_find(a, atlas_key(r)); ok {
		return
	}
	sg, has := system_glyph(s, r)
	if !has {
		return
	}
	f := &s.fonts[sg.font]
	k := f.per_em * em * a.scale
	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(&f.info, r, k, k, &x0, &y0, &x1, &y1)
	w, h := max(x1 - x0, 0), max(y1 - y0, 0)
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, atlas_key(r), w, h, x0, y0)
	if !ok || pixels == nil {
		return
	}
	stbtt.MakeCodepointBitmap(&f.info, raw_data(pixels), w, h, a.side, k, k, r)
	return g, true
}
