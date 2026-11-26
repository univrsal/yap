#+build wasi
package render

import "core:strings"

// The browser's fonts (web/glyphs.js): a canvas draws the character with
// whatever font the system has for it, and the client takes the pixels.
// They count as one font here, the browser's (index 0 of System_Fonts.fonts).

@(default_calling_convention = "c")
foreign _ {
	// How far a symbol moves the pen in ems, or an emoji's 1; -1 if the
	// browser has no font for it (emoji: no colour picture).
	yap_glyph_probe :: proc(cp: i32, emoji: i32) -> f64 ---
	// Draws a character (a symbol at px pixels to the em, or an emoji into a
	// side x side tile, fill of it taken up). Returns 1 if it worked.
	yap_glyph_render :: proc(cp: i32, emoji: i32, px: f64, side: i32, fill: f64) -> i32 ---
	// The last render's 0 width, 1 height, 2 x offset, 3 y offset.
	yap_glyph_info :: proc(which: i32) -> i32 ---
	// Copies the last render's pixels (a mask, or RGBA for an emoji), rows
	// `stride` pixels apart.
	yap_glyph_take :: proc(out: [^]u8, stride: i32) ---
}

@(private)
system_glyph_find :: proc(s: ^System_Fonts, r: rune) -> System_Glyph {
	advance := yap_glyph_probe(i32(r), 0)
	if advance < 0 {
		return {font = -1}
	}
	if len(s.fonts) == 0 {
		append(&s.fonts, System_Font{name = strings.clone("the browser's fonts")})
	}
	return {font = 0, advance = f32(advance)}
}

// system_glyph_cache puts a character's glyph from the browser's fonts into
// the atlas `a` for a font of em size `em` (logical pixels), if it is not
// there already. It fails once the atlas is full (it is then emptied before
// the next frame).
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
	if _, has := system_glyph(s, r); !has {
		return
	}
	if yap_glyph_render(i32(r), 0, f64(em * a.scale), 0, 0) == 0 {
		return
	}
	w, h := yap_glyph_info(0), yap_glyph_info(1)
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, atlas_key(r), w, h, yap_glyph_info(2), yap_glyph_info(3))
	if !ok || pixels == nil {
		return
	}
	yap_glyph_take(raw_data(pixels), a.side)
	return g, true
}
