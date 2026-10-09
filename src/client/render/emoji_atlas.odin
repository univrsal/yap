package render

import "core:slice"

/*
The emoji (proto/emoji.odin), as pictures: Apple Color Emoji's, in one
sheet (assets/emoji.webp, which scripts/emoji.py makes with the list of
which character is in which cell, emoji_cells.odin). They're in colour,
so they're drawn as pictures, in a texture of their own (Texture_Kind.Rgba,
mipmapped, since they're drawn a good deal smaller than they are), not
from a font's alpha atlas.

The sheet is EMOJI_SIDE pixels square, in EMOJI_COLUMNS columns of
EMOJI_CELL pixels, a character's cell being its index in EMOJI_CELLS. Its
last cell is blank: a white texel is put there, so that rects between
emoji (a button's frame in the picker) can be drawn from this texture
too, without switching to a font's atlas and back for each one.

The client decodes the sheet (it's a WebP: ui_images.odin, as it decodes
any picture) and hands the pixels to emoji_sheet_upload. Until then
emoji take their room in a line and aren't drawn.
*/

EMOJI_COLUMNS :: 32
EMOJI_CELL :: 64
EMOJI_SIDE :: EMOJI_COLUMNS * EMOJI_CELL
// The sheet's size in pixels, for whoever decodes it.
EMOJI_PIXELS :: EMOJI_SIDE * EMOJI_SIDE * 4

// How much room an emoji takes in a line, and how big it's drawn, in
// logical pixels. The same as the server's emoji (CUSTOM_EMOJI_*),
// which they're mixed with; a cell has a margin, so what's drawn in it
// is a little smaller than this.
EMOJI_ADVANCE :: f32(19)
EMOJI_SIZE :: f32(18)

@(private = "file")
WHITE_CELL :: EMOJI_COLUMNS * EMOJI_COLUMNS - 1 // the sheet is square

#assert(len(EMOJI_CELLS) < WHITE_CELL)

// emoji_cell is the sheet's cell for a character, if it's one of the
// emoji drawn from it.
emoji_cell :: proc(r: rune) -> (cell: int, ok: bool) {
	return slice.binary_search(EMOJI_CELLS[:], r)
}

// emoji_uv is the part of the sheet a cell is: u0, v0, u1, v1.
emoji_uv :: proc(cell: int) -> (u0, v0, u1, v1: f32) {
	x := f32(cell % EMOJI_COLUMNS * EMOJI_CELL)
	y := f32(cell / EMOJI_COLUMNS * EMOJI_CELL)
	return x / EMOJI_SIDE, y / EMOJI_SIDE, (x + EMOJI_CELL) / EMOJI_SIDE, (y + EMOJI_CELL) / EMOJI_SIDE
}

// emoji_white is a texel in the middle of the sheet's white cell.
@(private)
emoji_white :: proc() -> [2]f32 {
	x := f32(WHITE_CELL % EMOJI_COLUMNS * EMOJI_CELL + EMOJI_CELL / 2)
	y := f32(WHITE_CELL / EMOJI_COLUMNS * EMOJI_CELL + EMOJI_CELL / 2)
	return {x / EMOJI_SIDE, y / EMOJI_SIDE}
}

/*
emoji_sheet_upload makes the sheet's texture from its decoded pixels
(EMOJI_SIDE square, straight RGBA), which it writes the white cell into.
False if they aren't the right size.
*/
emoji_sheet_upload :: proc(r: ^Renderer, pixels: []u8, width, height: int) -> bool {
	if width != EMOJI_SIDE || height != EMOJI_SIDE || len(pixels) != EMOJI_PIXELS {
		return false
	}
	x0 := WHITE_CELL % EMOJI_COLUMNS * EMOJI_CELL
	y0 := WHITE_CELL / EMOJI_COLUMNS * EMOJI_CELL
	for y in y0 ..< y0 + EMOJI_CELL {
		line := pixels[(y * EMOJI_SIDE + x0) * 4:][:EMOJI_CELL * 4]
		for &b in line {
			b = 255
		}
	}
	gpu_texture_delete(&r.gpu, &r.emoji_texture)
	r.emoji_texture = gpu_texture_make(
		&r.gpu,
		.Rgba,
		EMOJI_SIDE,
		EMOJI_SIDE,
		pixels,
		mipmaps = true,
	)
	return r.emoji_texture != 0
}

// emoji_sheet_ready is whether the sheet is on the GPU, to be drawn from.
emoji_sheet_ready :: proc(r: ^Renderer) -> bool {
	return r.emoji_texture != 0
}
