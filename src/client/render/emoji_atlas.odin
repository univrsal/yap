package render

import "core:math"
import "core:slice"

// The emoji (proto/emoji.odin) are drawn as pictures from Blobmoji (a
// continuation of Google's older "blob" emoji, Apache 2.0), packed into one
// sheet (assets/emoji.webp). tools/emoji.py creates the sheet together with
// the list that maps each character to its cell (emoji_cells.odin). Emoji
// are in color, so they are drawn from a texture of their own
// (Texture_Kind.Rgba, with mipmaps because they are drawn smaller than their
// source size) instead of from a font's alpha atlas. Where the system has an
// emoji font we can draw, its pictures are used instead
// (sysemoji_native.odin), and the sheet only for what it lacks.
//
// The sheet is EMOJI_SIDE pixels square and has EMOJI_COLUMNS columns (and
// as many rows) of EMOJI_CELL pixels each, which leaves a strip on the
// right and at the bottom unused. A character's cell is its index in
// EMOJI_CELLS. The last cell is blank and gets a white texel, so rects
// between emoji (such as a button frame in the picker) can be drawn from
// this texture too without switching to a font's atlas and back.
//
// The client decodes the sheet (a WebP, see ui_images.odin) and passes the
// pixels to emoji_sheet_upload. Until then, emoji take up their space in a
// line but are not drawn.

EMOJI_COLUMNS :: 42
EMOJI_CELL :: 48
EMOJI_SIDE :: 2048
#assert(EMOJI_COLUMNS * EMOJI_CELL <= EMOJI_SIDE)
// The size of the sheet in bytes, as expected from the decoder.
EMOJI_PIXELS :: EMOJI_SIDE * EMOJI_SIDE * 4
// The margin around each picture in its cell, which keeps one's edge from
// bleeding into the next when the sheet is shrunk (tools/emoji.py), and how
// much of the cell the picture takes up as a result. The system's emoji are
// drawn as big (sysemoji_native.odin).
EMOJI_PADDING :: 2
EMOJI_FILL :: f32(EMOJI_CELL - 2 * EMOJI_PADDING) / EMOJI_CELL

// How much space an emoji takes up in a line and how big it is drawn, in
// logical pixels. These match the server's custom emoji (CUSTOM_EMOJI_*),
// which are mixed with these. A cell has a margin, so the drawn emoji is
// slightly smaller than this.
EMOJI_ADVANCE :: f32(19)
EMOJI_SIZE :: f32(18)

// emoji_side is how many physical pixels an emoji is drawn at `scale`.
emoji_side :: proc(scale: f32) -> i32 {
	return i32(math.round(EMOJI_SIZE * scale))
}

@(private = "file")
WHITE_CELL :: EMOJI_COLUMNS * EMOJI_COLUMNS - 1 // the sheet is square

#assert(len(EMOJI_CELLS) < WHITE_CELL)

// emoji_cell returns the sheet's cell for a character, if the character is
// one of the emoji drawn from it.
emoji_cell :: proc(r: rune) -> (cell: int, ok: bool) {
	return slice.binary_search(EMOJI_CELLS[:], r)
}

// emoji_uv returns the texture coordinates of a cell as u0, v0, u1, v1.
emoji_uv :: proc(cell: int) -> (u0, v0, u1, v1: f32) {
	x := f32(cell % EMOJI_COLUMNS * EMOJI_CELL)
	y := f32(cell / EMOJI_COLUMNS * EMOJI_CELL)
	return x / EMOJI_SIDE,
		y / EMOJI_SIDE,
		(x + EMOJI_CELL) / EMOJI_SIDE,
		(y + EMOJI_CELL) / EMOJI_SIDE
}

// emoji_white returns the texture coordinates of a texel in the middle of the
// sheet's white cell.
@(private)
emoji_white :: proc() -> [2]f32 {
	x := f32(WHITE_CELL % EMOJI_COLUMNS * EMOJI_CELL + EMOJI_CELL / 2)
	y := f32(WHITE_CELL / EMOJI_COLUMNS * EMOJI_CELL + EMOJI_CELL / 2)
	return {x / EMOJI_SIDE, y / EMOJI_SIDE}
}

// emoji_sheet_upload creates the sheet's texture from its decoded pixels
// (straight RGBA, EMOJI_SIDE pixels square) and writes the white cell into
// them. It returns false if the pixels have the wrong size.
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

// emoji_sheet_ready returns whether the sheet has been uploaded to the GPU.
emoji_sheet_ready :: proc(r: ^Renderer) -> bool {
	return r.emoji_texture != 0
}
