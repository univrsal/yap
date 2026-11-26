#+build wasi
package render

// A page can't read the system's font files (sysfont.odin), so the web
// client has the browser draw the characters the bundled faces lack
// (sysglyph_web.odin); Unifont where the browser has none either.

System_Lookup :: struct {}

system_lookup_destroy :: proc(l: ^System_Lookup) {}

@(private)
system_font_candidates :: proc(s: ^System_Fonts, r: rune, out: ^[dynamic]Font_File) {}

@(private)
system_font_open :: proc(s: ^System_Fonts, file: Font_File) -> int {
	return -1
}

@(private)
unmap_font_file :: proc(data: []u8) {}
