package client

import "core:math"
import stbtt "vendor:stb/truetype"

/*
The UI font: Noto Sans cut down to printable ASCII (8.6 KB, embedded with
#load; license in assets/NotoSans-OFL.txt), rasterized with stb_truetype.

Layout happens in logical pixels, but glyphs are rasterized at the
display's real density (`scale` physical pixels per logical pixel), so
text is sharp on high-DPI screens. The atlas is rebuilt whenever the
scale changes, e.g. when the window moves to another monitor.

Glyph advances are taken from the unscaled font metrics, so text widths,
and with them the whole layout, are the same at every scale.
*/

@(private = "file")
FONT_DATA := #load("assets/NotoSans-ascii.ttf")

FONT_SIZE   :: 15 // logical pixels
LINE_HEIGHT :: 18 // logical pixels; microui's default, which its layout metrics assume

FIRST_CHAR :: 32
CHAR_COUNT :: 95 // ' ' through '~'
FALLBACK_CHAR :: '?'

Font :: struct {
	info:    stbtt.fontinfo,
	ok:      bool,
	advance: [CHAR_COUNT]f32, // logical pixels
	// Distance from the top of a LINE_HEIGHT line box to the baseline.
	baseline: f32,

	// Atlas for the current scale (built by font_build_atlas).
	scale:   f32,
	pixels:  []u8, // width * height, one alpha byte per texel
	width:   i32,
	height:  i32,
	glyphs:  [CHAR_COUNT]stbtt.packedchar,
	// A few fully opaque texels, for drawing solid rectangles.
	white:   [2]f32,
}

font_init :: proc(f: ^Font) -> bool {
	if !stbtt.InitFont(&f.info, raw_data(FONT_DATA), 0) {
		return false
	}
	s := stbtt.ScaleForPixelHeight(&f.info, FONT_SIZE)
	for i in 0 ..< CHAR_COUNT {
		advance, lsb: i32
		stbtt.GetCodepointHMetrics(&f.info, rune(FIRST_CHAR + i), &advance, &lsb)
		f.advance[i] = f32(advance) * s
	}
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&f.info, &ascent, &descent, &line_gap)
	text_height := f32(ascent - descent) * s
	f.baseline = (LINE_HEIGHT - text_height) / 2 + f32(ascent) * s
	f.ok = true
	return true
}

font_destroy :: proc(f: ^Font) {
	delete(f.pixels)
	f.pixels = nil
}

// font_build_atlas rasterizes the glyphs for `scale` physical pixels per
// logical pixel.
font_build_atlas :: proc(f: ^Font, scale: f32) -> bool {
	delete(f.pixels)
	f.pixels = nil
	f.scale = scale

	// Start small and grow until everything fits. Two extra rows at the
	// bottom, outside the packing area, hold the white texels.
	for size: i32 = 128; size <= 4096; size *= 2 {
		pixels := make([]u8, int(size) * int(size + 2))
		spc: stbtt.pack_context
		if !stbtt.PackBegin(&spc, raw_data(pixels), size, size, size, 1, nil) {
			delete(pixels)
			return false
		}
		packed := stbtt.PackFontRange(&spc, raw_data(FONT_DATA), 0, FONT_SIZE * scale, FIRST_CHAR, CHAR_COUNT, &f.glyphs[0])
		stbtt.PackEnd(&spc)
		if !packed {
			delete(pixels)
			continue
		}

		white_row := int(size) * int(size)
		for i in 0 ..< 2 {
			pixels[white_row + i] = 255
			pixels[white_row + int(size) + i] = 255
		}
		f.pixels = pixels
		f.width, f.height = size, size + 2
		f.white = {1 / f32(f.width), (f32(size) + 1) / f32(f.height)}
		return true
	}
	return false
}

@(private = "file")
glyph_index :: proc(b: u8) -> int {
	c := int(b)
	if c < FIRST_CHAR || c >= FIRST_CHAR + CHAR_COUNT {
		c = FALLBACK_CHAR
	}
	return c - FIRST_CHAR
}

// Glyphs are indexed per UTF-8 sequence rather than per byte, so
// non-ASCII text measures and draws as one fallback glyph per character.
@(private = "file")
is_continuation_byte :: #force_inline proc(b: u8) -> bool {
	return b & 0xc0 == 0x80
}

font_text_width :: proc(f: ^Font, text: string) -> f32 {
	w: f32
	for b in transmute([]u8)text {
		if !is_continuation_byte(b) {
			w += f.advance[glyph_index(b)]
		}
	}
	return w
}

Glyph_Quad :: struct {
	x0, y0, x1, y1: f32, // logical pixels
	u0, v0, u1, v1: f32,
}

// font_layout calls `emit` for every visible glyph of `text`, with the
// top of its line box at `y` (all logical pixels). Glyph edges are snapped
// to physical pixels, which keeps small text crisp.
font_layout :: proc(f: ^Font, text: string, x, y: f32, data: rawptr, emit: proc(data: rawptr, q: Glyph_Quad)) {
	s := f.scale
	baseline := math.round((y + f.baseline) * s)
	pen := x
	for b in transmute([]u8)text {
		if is_continuation_byte(b) {
			continue
		}
		i := glyph_index(b)
		g := &f.glyphs[i]
		if g.x1 > g.x0 {
			px := math.round(pen * s + g.xoff)
			py := baseline + math.round(g.yoff)
			w, h := f32(g.x1 - g.x0), f32(g.y1 - g.y0)
			emit(data, Glyph_Quad{
				x0 = px / s, y0 = py / s, x1 = (px + w) / s, y1 = (py + h) / s,
				u0 = f32(g.x0) / f32(f.width), v0 = f32(g.y0) / f32(f.height),
				u1 = f32(g.x1) / f32(f.width), v1 = f32(g.y1) / f32(f.height),
			})
		}
		pen += f.advance[i]
	}
}
