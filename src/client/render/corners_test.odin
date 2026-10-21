#+build !wasi
package render

import "core:testing"
import mu "vendor:microui"

// Every shape, set of corners and radius comes back out of its icon id.
@(test)
test_rounded_ids_round_trip :: proc(t: ^testing.T) {
	for shape in Rounded_Shape {
		for bits in 0 ..< 16 {
			corners := transmute(Corners)u8(bits)
			for radius in i32(0) ..= ROUND_MAX {
				s, c, r, ok := rounded_of(rounded_id(shape, corners, radius))
				testing.expect(t, ok)
				testing.expect_value(t, s, shape)
				testing.expect_value(t, c, corners)
				testing.expect_value(t, r, radius)
			}
		}
	}
	// Ids outside the range are left to the other kinds of icon.
	_, _, _, ok := rounded_of(icon_id(.Close))
	testing.expect(t, !ok)
	_, _, _, ok = rounded_of(mu.Icon(IMAGE_ICON_BASE))
	testing.expect(t, !ok)
}

// The tiles fit in the atlas's width without overlapping, at every scale,
// and are a quarter of a disc or of a ring.
@(test)
test_corner_tiles :: proc(t: ^testing.T) {
	for scale in ([]f32{1, 1.25, 1.5, 2, 3}) {
		c: Corner_Tiles
		defer delete(c.at)
		WIDTH :: 256
		height := corner_tiles_layout(&c, scale, WIDTH, 3)
		height += 3
		pixels := make([]u8, WIDTH * int(height))
		defer delete(pixels)
		corner_tiles_draw(&c, pixels, WIDTH)

		owner := make([]int, len(pixels))
		defer delete(owner)
		for at, i in c.at {
			side := i32(i + 1)
			for kind in Corner_Kind {
				p := at[kind]
				testing.expect(t, p.x + side <= WIDTH && p.y + side <= height)
				for y in 0 ..< side {
					for x in 0 ..< side {
						o := &owner[(p.y + y) * WIDTH + p.x + x]
						testing.expectf(t, o^ == 0, "tiles overlap at scale %.2f", scale)
						o^ = 1
					}
				}
				texel :: proc(pixels: []u8, p: [2]i32, x, y: i32) -> u8 {
					return pixels[(p.y + y) * WIDTH + p.x + x]
				}
				// The corner itself is outside the curve.
				if side >= 3 {
					testing.expect_value(t, texel(pixels, p, 0, 0), 0)
				}
				// Next to the circle's centre is inside a disc, and inside
				// the hole of a ring that is wider than its line. (In a
				// tile of one texel, that texel is on the curve too.)
				inner := texel(pixels, p, side - 1, side - 1)
				if side == 1 {
					testing.expect(t, inner > 128)
				} else if kind == .Fill || f32(side) <= c.ring {
					testing.expect_value(t, inner, 255)
				} else if f32(side) > c.ring + 1 {
					testing.expect_value(t, inner, 0)
				}
				// Where the tile meets the straight edges, the curve has the
				// line's thickness for a ring and fills the tile for a disc.
				edge := texel(pixels, p, side - 1, 0)
				testing.expectf(t, edge >= 128, "edge %d at scale %.2f, radius %d", edge, scale, side)
			}
		}
	}
}
