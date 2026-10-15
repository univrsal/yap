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
// treated as narrow.
//
// The chart is only decoded once some text needs it, because most sessions
// never do, and only its bits are kept (32 bytes per character).
//
// Glyphs are scaled with nearest-neighbour sampling to keep their pixels
// square. This is exact at whole scales; at fractional scales some pixels end
// up one physical pixel wider than others. Not all glyphs would fit in one
// texture, so the glyphs that text uses are copied into an atlas at the
// current scale the first time they appear (unifont_cache).
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

// Slots per row of the atlas. The atlas is sized to hold this many slots
// squared (up to UNIFONT_MAX_ATLAS).
@(private = "file")
UNIFONT_SLOTS_PER_ROW :: 32
@(private = "file")
UNIFONT_MAX_ATLAS :: 2048

Unifont :: struct {
	loaded:             bool,
	failed:             bool,
	rows:               []u16, // 16 per character, top first; bit 15 is the leftmost pixel
	width:              []u8, // per character: 8, 16, or 0 for none

	// The atlas of glyphs drawn so far, rasterized for `scale`.
	scale:              f32,
	slots:              map[rune]i32,
	cell:               i32, // a slot's side (physical pixels), with a pixel of gap
	per_row:            i32,
	pixels:             []u8, // side * side, one alpha byte per texel; nil until needed
	side:               i32,
	full:               bool, // out of slots: start again next frame
	dirty_y0, dirty_y1: i32, // rows changed since the atlas was last uploaded
}

unifont_destroy :: proc(u: ^Unifont) {
	delete(u.rows)
	delete(u.width)
	delete(u.pixels)
	delete(u.slots)
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

// unifont_reset empties the atlas and prepares a new one for `scale`.
unifont_reset :: proc(u: ^Unifont, scale: f32) {
	delete(u.pixels)
	u.pixels = nil
	clear(&u.slots)
	u.scale = scale
	u.full = false
	u.cell = unifont_glyph_height(scale) + 1
	u.side = 256
	for u.side < u.cell * UNIFONT_SLOTS_PER_ROW && u.side < UNIFONT_MAX_ATLAS {
		u.side *= 2
	}
	u.per_row = u.side / u.cell
	u.dirty_y0, u.dirty_y1 = u.side, 0
}

// The number of glyphs the atlas holds. That is all slots except the last,
// which is solid white so that rects can be drawn from this atlas too
// (unifont_white). This way a run of emoji between rects does not need to
// switch textures.
unifont_capacity :: proc(u: ^Unifont) -> i32 {
	return u.per_row * u.per_row - 1
}

// unifont_pixels allocates the atlas's pixels, including its white slot, if
// that has not happened yet.
unifont_pixels :: proc(u: ^Unifont) {
	if u.pixels != nil {
		return
	}
	u.pixels = make([]u8, int(u.side) * int(u.side))
	slot := u.per_row * u.per_row - 1
	x0 := (slot % u.per_row) * u.cell
	y0 := (slot / u.per_row) * u.cell
	for y in 0 ..< u.cell - 1 {
		line := u.pixels[int(y0 + y) * int(u.side) + int(x0):]
		for x in 0 ..< u.cell - 1 {
			line[x] = 255
		}
	}
	u.dirty_y0 = min(u.dirty_y0, y0)
	u.dirty_y1 = max(u.dirty_y1, y0 + u.cell)
}

// unifont_white returns the texture coordinates of a texel in the middle of
// the white slot. It is not ok before the atlas has pixels.
unifont_white :: proc(u: ^Unifont) -> (uv: [2]f32, ok: bool) {
	if u.pixels == nil {
		return
	}
	slot := u.per_row * u.per_row - 1
	x := f32((slot % u.per_row) * u.cell) + f32(u.cell - 1) / 2
	y := f32((slot / u.per_row) * u.cell) + f32(u.cell - 1) / 2
	return {x / f32(u.side), y / f32(u.side)}, true
}

// The height of a glyph in physical pixels at `scale`.
unifont_glyph_height :: proc(scale: f32) -> i32 {
	return max(1, i32(math.round(UNIFONT_SIZE * scale)))
}

// unifont_cache puts a character's glyph in the atlas, if it is not there
// already, and returns its slot. Once the atlas is full this fails and the
// atlas is flagged to be emptied before the next frame.
unifont_cache :: proc(u: ^Unifont, r: rune) -> (slot: i32, ok: bool) {
	if s, found := u.slots[r]; found {
		return s, true
	}
	width := unifont_width(u, r)
	if width == 0 || u.full || u.side == 0 {
		return
	}
	slot = i32(len(u.slots))
	if slot >= unifont_capacity(u) {
		u.full = true
		return
	}
	unifont_pixels(u)

	h := unifont_glyph_height(u.scale)
	w := unifont_glyph_width(u, r)
	x0 := (slot % u.per_row) * u.cell
	y0 := (slot / u.per_row) * u.cell
	for y in 0 ..< h {
		// The source pixel under the center of this one.
		row := u.rows[int(r) * 16 + int(min((2 * y + 1) * 16 / (2 * h), 15))]
		line := u.pixels[int(y0 + y) * int(u.side) + int(x0):]
		for x in 0 ..< w {
			sx := min((2 * x + 1) * 16 / (2 * h), 15)
			if row & (0x8000 >> uint(sx)) != 0 {
				line[x] = 255
			}
		}
	}
	u.slots[r] = slot
	u.dirty_y0 = min(u.dirty_y0, y0)
	u.dirty_y1 = max(u.dirty_y1, y0 + u.cell)
	return slot, true
}

// The width of a glyph in physical pixels at the atlas's scale.
unifont_glyph_width :: proc(u: ^Unifont, r: rune) -> i32 {
	h := unifont_glyph_height(u.scale)
	return i32(math.round(f32(u.width[r]) * f32(h) / UNIFONT_SIZE))
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
