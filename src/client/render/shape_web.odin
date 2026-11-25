#+build wasi
package render

// The web client doesn't shape text (shape_native.odin needs kb_text_shape,
// which isn't built for the web yet): everything is drawn character by
// character, in the order it was typed.

Shaping :: struct {}

shaping_destroy :: proc(sh: ^Shaping) {}

shaping_clear :: proc(sh: ^Shaping) {}

shaping_frame :: proc(sh: ^Shaping) {}

needs_shaping :: proc(f: ^Font, text: string) -> bool {
	return false
}

shaped_text :: proc(f: ^Font, style: Font_Style, text: string) -> Shaped {
	return {}
}

shaped_glyph_cache :: proc(f: ^Font, font, id: u16) -> (g: Atlas_Glyph, ok: bool) {
	return
}
