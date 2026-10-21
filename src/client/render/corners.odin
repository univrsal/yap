package render

import "core:math"

// The pieces that rounded rects are made of (push_rounded in render.odin). A
// rounded rect is drawn as plain rects for its straight parts and a quarter
// of a disc, or of a ring for its border, in each rounded corner. The quarters
// are rasterized at the display's density into the bottom of each font atlas,
// below its white texels, so a rounded rect is drawn from the same texture as
// the text and rects around it and needs no draw call of its own.
//
// There is a tile for every radius in whole physical pixels up to
// ROUND_MAX logical pixels. Each tile is the top left corner, with the
// circle's centre at its bottom right. The other corners are drawn from the
// same tile mirrored.

// The largest corner radius, in logical pixels.
ROUND_MAX :: 12

Corner_Kind :: enum {
	Fill, // a quarter of a disc
	Ring, // a quarter of a ring one line thick (line_thickness)
}

Corner_Tiles :: struct {
	// Where each tile's top left texel is in the atlas, for the radius
	// `i + 1` physical pixels.
	at:   [][Corner_Kind][2]i32,
	// How thick the rings are, in physical pixels.
	ring: f32,
}

// line_thickness returns how many physical pixels thick a line that is one
// logical pixel thick is, rounded down to a whole number.
@(private)
line_thickness :: proc(s: f32) -> f32 {
	return max(1, math.floor(s + 0.001))
}

// corner_tiles_layout places the tiles for `scale` in rows of `width` texels,
// starting at row `top` of the atlas, and returns how many rows of texels they
// take. Tiles are a texel apart.
corner_tiles_layout :: proc(c: ^Corner_Tiles, scale: f32, width, top: i32) -> (height: i32) {
	delete(c.at)
	n := max(1, int(math.round(ROUND_MAX * scale)))
	c.at = make([][Corner_Kind][2]i32, n)
	c.ring = line_thickness(scale)
	x, y, row := i32(0), i32(0), i32(0)
	for i in 0 ..< n {
		side := i32(i + 1)
		for kind in Corner_Kind {
			if x + side > width {
				x, y, row = 0, y + row + 1, 0
			}
			c.at[i][kind] = {x, top + y}
			x += side + 1
			row = max(row, side)
		}
	}
	return y + row
}

// corner_tiles_draw rasterizes the tiles into an atlas `width` texels wide.
corner_tiles_draw :: proc(c: ^Corner_Tiles, pixels: []u8, width: i32) {
	for at, i in c.at {
		r := f32(i + 1)
		inner := r - c.ring
		for kind in Corner_Kind {
			pos := at[kind]
			for y in 0 ..< i32(i + 1) {
				for x in 0 ..< i32(i + 1) {
					// The distance of the texel's centre from the circle's.
					d := math.hypot(r - (f32(x) + 0.5), r - (f32(y) + 0.5))
					// The coverage fades over one texel across the edge.
					alpha := clamp(r - d + 0.5, 0, 1)
					if kind == .Ring && inner > 0 {
						alpha = max(alpha - clamp(inner - d + 0.5, 0, 1), 0)
					}
					index := int(pos.y + y) * int(width) + int(pos.x + x)
					pixels[index] = u8(math.round(alpha * 255))
				}
			}
		}
	}
}
