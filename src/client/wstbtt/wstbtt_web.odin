#+build wasi
/*
The web half of the font rasterizer: stb_truetype.c compiled by
emscripten alongside the client (see web/build.sh), bound here as plain
C symbols. The structs mirror stb_truetype.h exactly, since the C side
reads and writes them.
*/
package wstbtt

_buf :: struct {
	data:   [^]byte,
	cursor: i32,
	size:   i32,
}

fontinfo :: struct {
	userdata:                                     rawptr,
	data:                                         [^]byte,
	fontstart:                                    i32,
	numGlyphs:                                    i32,
	loca, head, glyf, hhea, hmtx, kern, gpos, svg: i32,
	index_map:                                    i32,
	indexToLocFormat:                             i32,
	cff:                                          _buf,
	charstrings:                                  _buf,
	gsubrs:                                       _buf,
	subrs:                                        _buf,
	fontdicts:                                    _buf,
	fdselect:                                     _buf,
}

packedchar :: struct {
	x0, y0, x1, y1:       u16,
	xoff, yoff, xadvance: f32,
	xoff2, yoff2:         f32,
}

pack_range :: struct {
	font_size:                        f32,
	first_unicode_codepoint_in_range: i32,
	array_of_unicode_codepoints:      [^]rune,
	num_chars:                        i32,
	chardata_for_range:               [^]packedchar,
	_, _:                             u8,
}

pack_context :: struct {
	user_allocator_context, pack_info:       rawptr,
	width, height, stride_in_bytes, padding: i32,
	skip_missing:                            b32,
	h_oversample, v_oversample:              u32,
	pixels:                                  [^]byte,
	nodes:                                   rawptr,
}

@(default_calling_convention = "c", link_prefix = "stbtt_")
foreign _ {
	InitFont :: proc(info: ^fontinfo, data: [^]byte, offset: i32) -> b32 ---
	FindGlyphIndex :: proc(info: ^fontinfo, unicode_codepoint: rune) -> i32 ---
	ScaleForPixelHeight :: proc(info: ^fontinfo, pixels: f32) -> f32 ---
	GetFontVMetrics :: proc(info: ^fontinfo, ascent, descent, lineGap: ^i32) ---
	GetCodepointHMetrics :: proc(info: ^fontinfo, codepoint: rune, advanceWidth, leftSideBearing: ^i32) ---
	PackBegin :: proc(spc: ^pack_context, pixels: [^]byte, width, height, stride_in_bytes, padding: i32, alloc_context: rawptr) -> b32 ---
	PackEnd :: proc(spc: ^pack_context) ---
	PackFontRanges :: proc(spc: ^pack_context, fontdata: [^]byte, font_index: i32, ranges: [^]pack_range, num_ranges: i32) -> b32 ---
}
