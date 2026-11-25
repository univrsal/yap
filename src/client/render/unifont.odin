package render

import stbi "client:wstbi"
import log "common:wlog"
import "core:math"

// The fallback font is GNU Unifont. It covers what Roboto lacks, such as
// Chinese, Japanese, Korean and most other scripts in the Basic Multilingual
// Plane. It is a bitmap font with a cell 16 pixels tall per character, which
// is 8 pixels wide for most alphabets and 16 for CJK. The font is embedded as
// the chart published by the Unifont project: all 65536 cells in a 256 x 256
// grid, below a header row and next to a header column. A cell does not
// store the width of its glyph, so a cell with nothing in its right half is
// treated as narrow. Where the system has a font for a character
// (sysfont.odin), that font is used instead.
//
// The chart is only decoded once some text needs it, because most sessions
// never do, and only its bits are kept (32 bytes per character).
//
// Glyphs are scaled by area: each physical pixel is as opaque as the share
// of it that the glyph's pixels cover. At whole scales that is every pixel of
// the chart becoming a solid square. At fractional scales (the channel list's
// bigger font, or a UI scale of 1.5) every pixel of the chart still takes the
// same room, with a soft edge where it ends partway into a physical pixel,
// instead of some becoming a physical pixel wider than others and the glyph
// looking jagged. Not all glyphs would fit in one texture, so the glyphs that
// text uses are copied into the font's fallback atlas (glyph_atlas.odin) at
// its scale the first time they appear (unifont_cache).
//
// Nothing is shaped or reordered. For example, Arabic is shown as its
// isolated letters from left to right.

@(private = "file")
UNIFONT_PNG := #load("../assets/unifont-16.0.04.png")

// The position where the grid starts in the chart, after its headers.
@(private = "file")
CHART_X :: 32
@(private = "file")
CHART_Y :: 64

UNIFONT_CHARS :: 0x10000
UNIFONT_SIZE :: 16 // cell height, logical pixels at scale 1
UNIFONT_ASCENT :: 14 // cell top to baseline

Unifont :: struct {
	loaded: bool,
	failed: bool,
	rows:   []u16, // 16 per character, top first; bit 15 is the leftmost pixel
	width:  []u8, // per character: 8, 16, or 0 for none
}

unifont_destroy :: proc(u: ^Unifont) {
	delete(u.rows)
	delete(u.width)
	u^ = {}
}

// unifont_width returns the width of a character's glyph in logical pixels,
// or 0 if Unifont has no glyph for it.
unifont_width :: proc(u: ^Unifont, r: rune) -> int {
	if r < 0 || r >= UNIFONT_CHARS {
		return 0
	}
	if !u.loaded && !u.failed {
		unifont_load(u)
	}
	if u.failed {
		return 0
	}
	return int(u.width[r])
}

@(private = "file")
unifont_load :: proc(u: ^Unifont) {
	u.failed = true
	png := UNIFONT_PNG
	w, h, comp: i32
	pixels := stbi.load_from_memory(raw_data(png), i32(len(png)), &w, &h, &comp, 1)
	if pixels == nil {
		log.warn("could not decode the fallback font")
		return
	}
	defer stbi.image_free(pixels)
	if w < CHART_X + 256 * 16 || h < CHART_Y + 256 * 16 {
		log.warn("the fallback font's chart is too small")
		return
	}

	u.rows = make([]u16, UNIFONT_CHARS * 16)
	u.width = make([]u8, UNIFONT_CHARS)
	for c in 0 ..< UNIFONT_CHARS {
		// Control characters and surrogates get no glyph, even though the
		// chart has boxes for them.
		if c < 0x20 || (c >= 0x7f && c < 0xa0) || (c >= 0xd800 && c < 0xe000) {
			continue
		}
		x0 := CHART_X + (c % 256) * 16
		y0 := CHART_Y + (c / 256) * 16
		ink: u16
		for j in 0 ..< 16 {
			line := pixels[(y0 + j) * int(w) + x0:]
			row: u16
			for i in 0 ..< 16 {
				// Black on white.
				if line[i] < 128 {
					row |= 0x8000 >> uint(i)
				}
			}
			u.rows[c * 16 + j] = row
			ink |= row
		}
		switch {
		case ink & 0xff != 0:
			u.width[c] = 16
		case ink != 0:
			u.width[c] = 8
		case c == 0x3000:
			// The ideographic space is blank but as wide as the characters
			// around it.
			u.width[c] = 16
		}
	}
	u.failed = false
	u.loaded = true
}

// The height of a glyph in physical pixels at `scale`.
unifont_glyph_height :: proc(scale: f32) -> i32 {
	return max(1, i32(math.round(UNIFONT_SIZE * scale)))
}

// The width of a glyph in physical pixels at `scale`.
unifont_glyph_width :: proc(u: ^Unifont, r: rune, scale: f32) -> i32 {
	h := unifont_glyph_height(scale)
	return i32(math.round(f32(u.width[r]) * f32(h) / UNIFONT_SIZE))
}

// unifont_cache puts a character's glyph in the atlas `a`, at the atlas's
// scale, if it is not there already. It fails once the atlas is full (it is
// then emptied before the next frame).
unifont_cache :: proc(u: ^Unifont, a: ^Glyph_Atlas, r: rune) -> (g: Atlas_Glyph, ok: bool) {
	if g, ok = glyph_atlas_find(a, r); ok {
		return
	}
	if unifont_width(u, r) == 0 {
		return
	}
	h := unifont_glyph_height(a.scale)
	w := unifont_glyph_width(u, r, a.scale)
	top := -i32(math.round(UNIFONT_ASCENT * f32(h) / UNIFONT_SIZE))
	pixels: []u8
	g, pixels, ok = glyph_atlas_add(a, r, w, h, 0, top)
	if !ok {
		return
	}
	glyph := u.rows[int(r) * 16:][:16]
	k := f32(16) / f32(h) // chart pixels per physical pixel, on each side
	for y in 0 ..< h {
		ya, yb := f32(y) * k, f32(y + 1) * k
		line := pixels[int(y) * int(a.side):]
		for x in 0 ..< w {
			xa, xb := f32(x) * k, f32(x + 1) * k
			// How much of this pixel the chart's set pixels cover.
			cover: f32
			for sy := int(ya); sy < 16 && f32(sy) < yb; sy += 1 {
				dy := min(yb, f32(sy + 1)) - max(ya, f32(sy))
				for sx := int(xa); sx < 16 && f32(sx) < xb; sx += 1 {
					if glyph[sy] & (0x8000 >> uint(sx)) != 0 {
						cover += dy * (min(xb, f32(sx + 1)) - max(xa, f32(sx)))
					}
				}
			}
			line[x] = u8(math.round(clamp(cover / (k * k), 0, 1) * 255))
		}
	}
	return g, true
}

// is_ignorable returns whether a character only affects how other characters
// are shown (joiners, variation selectors, direction marks and so on; these
// are the BMP characters with Unicode's Default_Ignorable_Code_Point
// property). Such characters are drawn as nothing at all, although the
// Unifont chart has labelled boxes for them.
is_ignorable :: proc(r: rune) -> bool {
	switch r {
	case 0x00ad, 0x034f, 0x061c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x3164, 0xfeff, 0xffa0:
		return true
	case 0x180b ..= 0x180f, 0x200b ..= 0x200f, 0x202a ..= 0x202e, 0x2060 ..= 0x206f:
		return true
	case 0xfe00 ..= 0xfe0f, 0xfff0 ..= 0xfff8:
		return true
	}
	return false
}
