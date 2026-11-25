package render

// Shaped text (shape_native.odin): what shaping a string gives, the same on
// every platform; the web client never makes any (shape_web.odin).

Shaped_Kind :: enum u8 {
	Glyph, // a glyph of a shaping font
	Char, // a character drawn as it would be unshaped (layout_rune)
}

Shaped_Glyph :: struct {
	kind:   Shaped_Kind,
	font:   u16, // the shaping font (.Glyph)
	id:     u16, // its glyph (.Glyph)
	r:      rune, // the character (.Char)
	at:     int, // the index of the (first) character it is drawn for
	x:      f32, // the pen position from the start of the text (logical pixels, unzoomed)
	dx, dy: f32, // the glyph's offset from there, y up (.Glyph)
}

Shaped :: struct {
	glyphs: []Shaped_Glyph, // in the order they are drawn
	width:  f32, // logical pixels, unzoomed
	used:   u64, // the frame it was last used in
}

