package client

import "core:math"
import "core:slice"
import "core:unicode/utf8"
import stbtt "wstbtt"

/*
The UI font: Roboto (embedded with #load), rasterized with stb_truetype.
Every character the font has is used: its Latin, Greek and Cyrillic
letters and common punctuation and symbols. Anything else comes from
Unifont (ui_unifont.odin) if it has it, and draws as the replacement
character if not.

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

	// The fallback font, with an atlas of its own.
	uni:        Unifont,
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
	unifont_destroy(&f.uni)
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

// Which font a character is drawn from.
@(private = "file")
Glyph_Source :: enum {
	Roboto, // the index is into the Font's arrays
	Unifont, // the index is the character itself
	None, // draws nothing and takes no room (is_ignorable)
}

// find_glyph finds a character's glyph, or the fallback's. Invalid UTF-8
// reaches here as utf8.RUNE_ERROR, so it shows as the fallback too.
@(private = "file")
find_glyph :: proc(f: ^Font, r: rune) -> (index: int, source: Glyph_Source) {
	if r >= 0 && r < len(f.ascii) {
		return int(f.ascii[r]), .Roboto
	}
	if i, found := slice.binary_search(f.codepoints, r); found {
		return i, .Roboto
	}
	if is_ignorable(r) {
		return 0, .None
	}
	if unifont_width(&f.uni, r) > 0 {
		return int(r), .Unifont
	}
	return int(f.fallback), .Roboto
}

font_text_width :: proc(f: ^Font, text: string) -> f32 {
	w: f32
	for r in text {
		i, source := find_glyph(f, r)
		switch source {
		case .Roboto:
			w += f.advance[i]
		case .Unifont:
			w += f32(f.uni.width[i])
		case .None:
		}
	}
	return w
}

// font_cache_glyphs puts the Unifont glyphs `text` needs in their atlas,
// ahead of font_layout; the renderer uploads what changed in between.
font_cache_glyphs :: proc(f: ^Font, text: string) {
	for r in text {
		if _, source := find_glyph(f, r); source == .Unifont {
			unifont_cache(&f.uni, r)
		}
	}
}

Glyph_Quad :: struct {
	x0, y0, x1, y1: f32, // logical pixels
	u0, v0, u1, v1: f32,
	unifont:        bool, // from the Unifont atlas rather than the font's
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
		i, source := find_glyph(f, r)
		switch source {
		case .None:
		case .Unifont:
			u := &f.uni
			if slot, ok := unifont_cache(u, r); ok && u.scale == s {
				h := f32(unifont_glyph_height(s))
				w := f32(unifont_glyph_width(u, r))
				px := math.round(pen * s)
				py := baseline - math.round(UNIFONT_ASCENT * h / UNIFONT_SIZE)
				sx := f32((slot % u.per_row) * u.cell)
				sy := f32((slot / u.per_row) * u.cell)
				side := f32(u.side)
				emit(
					data,
					Glyph_Quad {
						x0 = px / s,
						y0 = py / s,
						x1 = (px + w) / s,
						y1 = (py + h) / s,
						u0 = sx / side,
						v0 = sy / side,
						u1 = (sx + w) / side,
						v1 = (sy + h) / side,
						unifont = true,
					},
				)
			} else {
				// The atlas is full: this frame makes do with the
				// fallback, in the room the glyph would have had.
				emit_glyph(f, int(f.fallback), pen, baseline, data, emit)
			}
			pen += f32(u.width[i])
		case .Roboto:
			emit_glyph(f, i, pen, baseline, data, emit)
			pen += f.advance[i]
		}
	}
}

// emit_glyph emits one of Roboto's glyphs, at `pen` (logical pixels) on
// `baseline` (physical ones).
@(private = "file")
emit_glyph :: proc(
	f: ^Font,
	i: int,
	pen, baseline: f32,
	data: rawptr,
	emit: proc(data: rawptr, q: Glyph_Quad),
) {
	s := f.scale
	g := &f.glyphs[i]
	if g.x1 <= g.x0 {
		return
	}
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
