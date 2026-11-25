package render

import "core:math"

// The fallback atlas holds the glyphs that come from neither a face's own
// atlas nor the emoji sheet: Unifont's (unifont.odin) and the system's fonts'
// (sysfont.odin). Each font has one, rasterized at the font's scale like its
// faces' atlases, but unlike those it starts empty and gets a glyph the first
// time text needs it, because these fonts have far too many glyphs to
// rasterize all of them up front (a Chinese font has tens of thousands).
//
// Glyphs are packed on shelves: rows as tall as the first glyph put on them,
// which later glyphs of about the same height share, left to right. Text in
// one font has glyphs of nearly one height, so little room is lost. When a
// glyph doesn't fit any more, the atlas is flagged as full and emptied before
// the next frame, which then puts in only what it draws (as with Unifont's
// slots before).
//
// A glyph is found by its character alone. A character's glyph comes from
// Unifont or from a system font, never both: what the system fonts offer is
// fixed for a character (sysfont.odin), and the atlas is emptied when they
// are turned on or off.

// How many glyphs as tall as the chosen line fit across the atlas (it is
// sized for this many, up to GLYPH_ATLAS_MAX).
@(private = "file")
GLYPH_ATLAS_PER_ROW :: 32
// The same for the color emoji, which take four times the memory.
@(private = "file")
EMOJI_ATLAS_PER_ROW :: 24
GLYPH_ATLAS_MAX :: 2048
// Pixels between glyphs, so that filtering one doesn't pull in its neighbor.
@(private = "file")
GLYPH_GAP :: 1
// The size of the solid block that rects are drawn from (glyph_atlas_white).
@(private = "file")
WHITE_SIDE :: 4

// A glyph in the atlas: where it is and how it sits on the pen position and
// baseline (all physical pixels).
Atlas_Glyph :: struct {
	x, y, w, h: i32,
	xoff, yoff: i32, // from the pen to the left edge, and from the baseline to the top
}

@(private = "file")
Shelf :: struct {
	y, h: i32, // its top and height
	x:    i32, // where the next glyph goes
}

Glyph_Atlas :: struct {
	// RGBA pixels (4 bytes each, for color emoji) rather than coverage (one
	// byte). Set before the first glyph_atlas_reset; kept by resets.
	rgba:               bool,
	scale:              f32, // physical pixels per logical pixel of the font
	glyphs:             map[u32]Atlas_Glyph, // by atlas_key or shaped_key
	pixels:             []u8, // side * side texels (glyph_atlas_bytes each); nil until needed
	side:               i32,
	shelves:            [dynamic]Shelf,
	bottom:             i32, // the first row below the last shelf
	white:              [2]f32, // texture coordinates in the middle of the white block
	full:               bool, // out of room: start again next frame
	dirty_y0, dirty_y1: i32, // rows changed since the atlas was last uploaded
}

glyph_atlas_destroy :: proc(a: ^Glyph_Atlas) {
	delete(a.pixels)
	delete(a.glyphs)
	delete(a.shelves)
	a^ = {}
}

// glyph_atlas_reset empties the atlas and prepares a new one for `scale`.
glyph_atlas_reset :: proc(a: ^Glyph_Atlas, scale: f32) {
	delete(a.pixels)
	a.pixels = nil
	clear(&a.glyphs)
	clear(&a.shelves)
	a.scale = scale
	a.full = false
	a.bottom = 0
	// Room for a few rows of Unifont's 16-pixel glyphs (about as tall as the
	// system fonts' glyphs and the emoji at this size), the way its slots
	// were sized. Color emoji take four times the memory and are fewer, so
	// their atlas is made for fewer.
	line := max(1, i32(math.round(UNIFONT_SIZE * scale))) + GLYPH_GAP
	a.side = 256
	per_row: i32 = EMOJI_ATLAS_PER_ROW if a.rgba else GLYPH_ATLAS_PER_ROW
	for a.side < line * per_row && a.side < GLYPH_ATLAS_MAX {
		a.side *= 2
	}
	a.dirty_y0, a.dirty_y1 = a.side, 0
}

// glyph_atlas_find returns a glyph, if it is in the atlas.
glyph_atlas_find :: proc(a: ^Glyph_Atlas, key: u32) -> (g: Atlas_Glyph, ok: bool) {
	return a.glyphs[key]
}

// glyph_atlas_add makes room for a glyph of w x h pixels and returns the
// pixels to draw it into (rows `side` texels apart, glyph_atlas_bytes each).
// Once there is no room, it fails
// and the atlas is flagged to be emptied before the next frame. The glyph is
// found by `key` afterwards.
glyph_atlas_add :: proc(
	a: ^Glyph_Atlas,
	key: u32,
	w, h, xoff, yoff: i32,
) -> (
	g: Atlas_Glyph,
	pixels: []u8,
	ok: bool,
) {
	if a.full || a.side == 0 {
		return
	}
	if w <= 0 || h <= 0 {
		// Blank (a space): nothing to draw, but known.
		a.glyphs[key] = {xoff = xoff, yoff = yoff}
		return a.glyphs[key], nil, true
	}
	glyph_atlas_pixels(a)
	x, y, placed := place(a, w, h)
	if !placed {
		a.full = true
		return
	}
	g = {x, y, w, h, xoff, yoff}
	a.glyphs[key] = g
	a.dirty_y0 = min(a.dirty_y0, y)
	a.dirty_y1 = max(a.dirty_y1, y + h)
	return g, a.pixels[(int(y) * int(a.side) + int(x)) * glyph_atlas_bytes(a):], true
}

// place finds room for w x h pixels on a shelf, or starts a new one.
@(private = "file")
place :: proc(a: ^Glyph_Atlas, w, h: i32) -> (x, y: i32, ok: bool) {
	if w + GLYPH_GAP > a.side {
		return
	}
	// The lowest shelf it fits on without wasting more than a quarter of the
	// shelf's height.
	best := -1
	for s, i in a.shelves {
		if h <= s.h && h >= s.h - s.h / 4 - 2 && s.x + w + GLYPH_GAP <= a.side {
			if best < 0 || s.h < a.shelves[best].h {
				best = i
			}
		}
	}
	if best < 0 {
		if a.bottom + h + GLYPH_GAP > a.side {
			return
		}
		append(&a.shelves, Shelf{y = a.bottom, h = h})
		a.bottom += h + GLYPH_GAP
		best = len(a.shelves) - 1
	}
	s := &a.shelves[best]
	x, y = s.x, s.y
	s.x += w + GLYPH_GAP
	return x, y, true
}

// glyph_atlas_pixels allocates the atlas's pixels, including a block of
// white texels that rects can be drawn from, so that a rect between glyphs
// from this atlas doesn't need to switch textures.
glyph_atlas_pixels :: proc(a: ^Glyph_Atlas) {
	if a.pixels != nil || a.side == 0 {
		return
	}
	bytes := glyph_atlas_bytes(a)
	a.pixels = make([]u8, int(a.side) * int(a.side) * bytes)
	x, y, _ := place(a, WHITE_SIDE, WHITE_SIDE)
	for j in 0 ..< i32(WHITE_SIDE) {
		for i in 0 ..< i32(WHITE_SIDE) {
			at := (int(y + j) * int(a.side) + int(x + i)) * bytes
			for &b in a.pixels[at:][:bytes] {
				b = 255
			}
		}
	}
	a.white = {
		(f32(x) + WHITE_SIDE / 2) / f32(a.side),
		(f32(y) + WHITE_SIDE / 2) / f32(a.side),
	}
	a.dirty_y0 = min(a.dirty_y0, y)
	a.dirty_y1 = max(a.dirty_y1, y + WHITE_SIDE)
}

// glyph_atlas_white returns the texture coordinates of a white texel. It is
// not ok before the atlas has pixels.
glyph_atlas_white :: proc(a: ^Glyph_Atlas) -> (uv: [2]f32, ok: bool) {
	if a.pixels == nil {
		return
	}
	return a.white, true
}

// glyph_atlas_bytes is how many bytes a texel of the atlas takes.
glyph_atlas_bytes :: proc(a: ^Glyph_Atlas) -> int {
	return 4 if a.rgba else 1
}

// atlas_key is how a character's glyph is found in an atlas: by the
// character, as each character has one glyph (Unifont's, a system font's or
// an emoji's).
atlas_key :: proc(r: rune) -> u32 {
	return u32(r)
}

// shaped_key is how a glyph of shaped text is found: by its font (a
// shaping font's number, shape_native.odin) and its index in the font, which
// may be a form that no character stands for (a ligature, or an Arabic
// letter's initial form).
shaped_key :: proc(font, glyph: u16) -> u32 {
	return 0x8000_0000 | u32(font) << 16 | u32(glyph)
}
