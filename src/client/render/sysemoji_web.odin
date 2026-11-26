#+build wasi
package render

// The browser's color emoji (web/glyphs.js), drawn by a canvas with whatever
// emoji font the system has, where it has a colored picture of an emoji;
// the bundled sheet's picture otherwise (sysemoji_native.odin has the other
// platforms'). There is no font to name or open: a glyph is just whether
// the browser draws it.

System_Emoji :: struct {}

system_emoji_destroy :: proc(e: ^System_Emoji) {}

system_emoji_glyph :: proc(s: ^System_Fonts, r: rune) -> (glyph: int, ok: bool) {
	if s == nil || !s.emoji_enabled {
		return
	}
	found: bool
	if glyph, found = s.emoji_found[r]; !found {
		glyph = 1 if yap_glyph_probe(i32(r), 1) >= 0 else 0
		s.emoji_found[r] = glyph
	}
	return glyph, glyph != 0
}

system_emoji_cache :: proc(
	s: ^System_Fonts,
	a: ^Glyph_Atlas,
	r: rune,
	side: i32,
	fill: f32,
) -> (
	g: Atlas_Glyph,
	ok: bool,
) {
	if g, ok = glyph_atlas_find(a, atlas_key(r)); ok {
		return
	}
	if _, has := system_emoji_glyph(s, r); !has {
		return
	}
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, atlas_key(r), side, side, 0, 0)
	if !ok || pixels == nil {
		return
	}
	if yap_glyph_render(i32(r), 1, 0, side, f64(fill)) == 0 {
		// Not drawable after all: the sheet's picture from now on.
		s.emoji_found[r] = 0
		ok = false
		return
	}
	yap_glyph_take(raw_data(pixels), a.side)
	return
}

// system_emoji_name returns what emoji are drawn from, or "" if the browser
// has no emoji font that draws in color.
system_emoji_name :: proc(s: ^System_Fonts) -> string {
	if _, ok := system_emoji_glyph(s, 0x1f600); ok {
		return "the browser's emoji font"
	}
	return ""
}
