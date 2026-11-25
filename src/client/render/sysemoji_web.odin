#+build wasi
package render

// A page can't read the system's emoji font (sysemoji_native.odin), so the
// web client draws its emoji from the bundled sheet.

System_Emoji :: struct {}

system_emoji_destroy :: proc(e: ^System_Emoji) {}

system_emoji_glyph :: proc(s: ^System_Fonts, r: rune) -> (glyph: int, ok: bool) {
	return
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
	return
}

system_emoji_name :: proc(s: ^System_Fonts) -> string {
	return ""
}
