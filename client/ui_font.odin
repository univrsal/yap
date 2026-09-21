package client

import "core:math"
import "core:slice"
import "core:unicode/utf8"
import stbtt "wstbtt"

/*
The UI font: Roboto (embedded with #load), rasterized with stb_truetype.
Every character the font has is used: its Latin, Greek and Cyrillic
letters and common punctuation and symbols. Anything else draws as the
replacement character.

Layout happens in logical pixels, but glyphs are rasterized at the
display's real density (`scale` physical pixels per logical pixel), so
text is sharp on high-DPI screens. The atlas is rebuilt whenever the
scale changes, e.g. when the window moves to another monitor.

Glyph advances are taken from the unscaled font metrics, so text widths,
and with them the whole layout, are the same at every scale.
*/

@(private = "file")
FONT_DATA := #load("assets/Roboto-Regular.ttf")

FONT_SIZE :: 15 // logical pixels
LINE_HEIGHT :: 18 // logical pixels; microui's default, which its layout metrics assume

// Shown for characters the font doesn't have: the first of these it does.
FALLBACK_CHARS :: [?]rune{utf8.RUNE_ERROR, '?'}

Font :: struct {
	info:       stbtt.fontinfo,
	ok:         bool,
	// The characters we have glyphs for, sorted; the arrays below are
	// indexed the same way.
	codepoints: []rune,
	advance:    []f32, // logical pixels
	glyphs:     []stbtt.packedchar, // for the current atlas
	ascii:      [128]i32, // index of each ASCII character, or -1
	fallback:   i32,
	// Distance from the top of a LINE_HEIGHT line box to the baseline.
	baseline:   f32,

	// Atlas for the current scale (built by font_build_atlas).
	scale:      f32,
	pixels:     []u8, // width * height, one alpha byte per texel
	width:      i32,
	height:     i32,
	// A few fully opaque texels, for drawing solid rectangles.
	white:      [2]f32,
}

font_init :: proc(f: ^Font) -> bool {
	if !stbtt.InitFont(&f.info, raw_data(FONT_DATA), 0) {
		return false
	}

	// Everything in the Basic Multilingual Plane the font has a glyph for,
	// except control characters.
	codepoints := make([dynamic]rune)
	for r in rune(0x20) ..< 0x10000 {
		if (r >= 0x7f && r < 0xa0) || (r >= 0xd800 && r < 0xe000) {
			continue
		}
		if stbtt.FindGlyphIndex(&f.info, r) != 0 {
			append(&codepoints, r)
		}
	}
	if len(codepoints) == 0 {
		delete(codepoints)
		return false
	}
	f.codepoints = codepoints[:]
	f.advance = make([]f32, len(f.codepoints))
	f.glyphs = make([]stbtt.packedchar, len(f.codepoints))

	s := stbtt.ScaleForPixelHeight(&f.info, FONT_SIZE)
	for r, i in f.codepoints {
		advance, lsb: i32
		stbtt.GetCodepointHMetrics(&f.info, r, &advance, &lsb)
		f.advance[i] = f32(advance) * s
	}

	f.fallback = 0
	for r in FALLBACK_CHARS {
		if i, found := slice.binary_search(f.codepoints, r); found {
			f.fallback = i32(i)
			break
		}
	}
	for &index, c in f.ascii {
		i, found := slice.binary_search(f.codepoints, rune(c))
		index = i32(i) if found else f.fallback
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
	delete(f.codepoints)
	delete(f.advance)
	delete(f.glyphs)
	// Everything, so a font built again asks for a new atlas rather
	// than trusting the one this scale used to have (see render).
	f^ = {}
}

// font_build_atlas rasterizes the glyphs for `scale` physical pixels per
// logical pixel.
font_build_atlas :: proc(f: ^Font, scale: f32) -> bool {
	delete(f.pixels)
	f.pixels = nil
	f.scale = scale

	// Start small and grow until everything fits. Two extra rows at the
	// bottom, outside the packing area, hold the white texels.
	for size: i32 = 256; size <= 4096; size *= 2 {
		pixels := make([]u8, int(size) * int(size + 2))
		spc: stbtt.pack_context
		if !stbtt.PackBegin(&spc, raw_data(pixels), size, size, size, 1, nil) {
			delete(pixels)
			return false
		}
		r := stbtt.pack_range {
			font_size                   = FONT_SIZE * scale,
			array_of_unicode_codepoints = raw_data(f.codepoints),
			num_chars                   = i32(len(f.codepoints)),
			chardata_for_range          = raw_data(f.glyphs),
		}
		packed := stbtt.PackFontRanges(&spc, raw_data(FONT_DATA), 0, &r, 1)
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

// glyph_index finds a character's glyph, or the fallback's. Invalid UTF-8
// reaches here as utf8.RUNE_ERROR, so it shows as the fallback too.
@(private = "file")
glyph_index :: proc(f: ^Font, r: rune) -> int {
	if r >= 0 && r < len(f.ascii) {
		return int(f.ascii[r])
	}
	if i, found := slice.binary_search(f.codepoints, r); found {
		return i
	}
	return int(f.fallback)
}

font_text_width :: proc(f: ^Font, text: string) -> f32 {
	w: f32
	for r in text {
		w += f.advance[glyph_index(f, r)]
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
font_layout :: proc(
	f: ^Font,
	text: string,
	x, y: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) {
	s := f.scale
	baseline := math.round((y + f.baseline) * s)
	pen := x
	for r in text {
		i := glyph_index(f, r)
		g := &f.glyphs[i]
		if g.x1 > g.x0 {
			px := math.round(pen * s + g.xoff)
			py := baseline + math.round(g.yoff)
			w, h := f32(g.x1 - g.x0), f32(g.y1 - g.y0)
			emit(
				data,
				Glyph_Quad {
					x0 = px / s,
					y0 = py / s,
					x1 = (px + w) / s,
					y1 = (py + h) / s,
					u0 = f32(g.x0) / f32(f.width),
					v0 = f32(g.y0) / f32(f.height),
					u1 = f32(g.x1) / f32(f.width),
					v1 = f32(g.y1) / f32(f.height),
				},
			)
		}
		pen += f.advance[i]
	}
}
