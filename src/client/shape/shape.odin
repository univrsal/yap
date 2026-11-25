// Text shaping (see yap_shape.c, over kb_text_shape, zlib license), for
// render/shape.odin. Build the library with build.sh / build.bat at the repo
// root. The web client doesn't shape text (render/shape_web.odin).
package shape

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_shape.lib"
} else {
	@(private)
	LIB :: "libyap_shape.a"
}

when !#exists(LIB) {
	#panic(
		"src/client/shape/" + LIB + " is missing; build it with build.sh (or build.bat on Windows)",
	)
}

foreign import lib {LIB}

OK :: 0
TOO_SMALL :: 1 // the arrays were too small; the counts say how big they need to be
ERROR :: -1

// A glyph of shaped text. Advances and offsets are in the font's units.
Glyph :: struct {
	id:       u16, // the glyph in its font (0: none)
	font:     u16, // the font it is from, as font_add numbered it
	cluster:  c.int, // the index of the (first) codepoint it was made from
	advance:  c.int,
	x_offset: c.int,
	y_offset: c.int,
}

// A run of glyphs of one direction, script and font.
Run :: struct {
	first_glyph, glyph_count: c.int,
	first, count:             c.int, // its codepoints
	rtl:                      c.int, // right to left; its glyphs are in visual order nonetheless
}

@(default_calling_convention = "c", link_prefix = "ys_")
foreign lib {
	// font_add reads font `index` of a font file (which must stay in memory
	// until the font is removed) and returns its number, or -1.
	font_add :: proc(data: rawptr, size: c.int, index: c.int) -> c.int ---
	font_remove :: proc(font: c.int) ---
	// shutdown removes all fonts and frees everything.
	shutdown :: proc() ---
	// shape shapes a line of `count` codepoints, each with the number of its
	// font (a number that isn't a font's makes glyphs 0 for those codepoints,
	// one each, for the caller to draw itself).
	shape :: proc(codepoints: [^]rune, font_of: [^]u16, count: c.int, glyphs: [^]Glyph, glyph_capacity: c.int, glyph_count: ^c.int, runs: [^]Run, run_capacity: c.int, run_count: ^c.int, paragraph_rtl: ^c.int) -> c.int ---
}
