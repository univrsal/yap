package main

import "core:testing"

import "tui"

// A 2 x 4 pixel PNG: the upper two rows red, the lower two blue.
RED_OVER_BLUE_PNG := [?]u8 {
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x08, 0x02, 0x00, 0x00, 0x00, 0x2b, 0x8d, 0x79,
	0x6e, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
	0x44, 0x0c, 0x50, 0x0a, 0xce, 0x00, 0x51, 0x00, 0x6f, 0xac, 0x07, 0xf9, 0x20, 0x8c, 0xeb, 0xe3,
	0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
}

@(test)
test_a_png_is_decoded_into_cells :: proc(t: ^testing.T) {
	pic := picture_decode(RED_OVER_BLUE_PNG[:], 56, 14)
	defer {
		delete(pic.top)
		delete(pic.bottom)
	}
	testing.expect(t, !pic.failed)
	testing.expect_value(t, pic.cols, 2)
	testing.expect_value(t, pic.rows, 2) // four pixels high, two to a cell
	// Cell row 0 is red over red, row 1 blue over blue.
	testing.expect_value(t, pic.top[0], Pixel{255, 0, 0})
	testing.expect_value(t, pic.bottom[1], Pixel{255, 0, 0})
	testing.expect_value(t, pic.top[2], Pixel{0, 0, 255})
	testing.expect_value(t, pic.bottom[3], Pixel{0, 0, 255})
}

@(test)
test_garbage_is_not_a_picture :: proc(t: ^testing.T) {
	junk := [?]u8{1, 2, 3, 4, 5}
	pic := picture_decode(junk[:], 56, 14)
	testing.expect(t, pic.failed)
	empty := picture_decode(nil, 56, 14)
	testing.expect(t, empty.failed)
}

@(test)
test_scaling_keeps_the_proportions_and_fits :: proc(t: ^testing.T) {
	// 200 x 100 pixels of mid grey, into 40 x 10 cells at most.
	rgba := make([]u8, 200 * 100 * 4)
	defer delete(rgba)
	for i in 0 ..< len(rgba) {
		rgba[i] = 128 if i % 4 != 3 else 255
	}
	pic := picture_scale(rgba, 200, 100, 40, 10)
	defer {
		delete(pic.top)
		delete(pic.bottom)
	}
	testing.expect_value(t, pic.cols, 40) // as wide as allowed
	testing.expect_value(t, pic.rows, 10) // 40 x 20 pixels is 2:1, as is the picture
	testing.expect_value(t, pic.top[0], Pixel{128, 128, 128})
	// A tall picture is limited by the rows.
	tall := picture_scale(rgba, 100, 200, 40, 10)
	defer {
		delete(tall.top)
		delete(tall.bottom)
	}
	testing.expect_value(t, tall.rows, 10)
	testing.expect_value(t, tall.cols, 10)
	// A small picture is not blown up.
	small := picture_scale(rgba, 6, 4, 40, 10)
	defer {
		delete(small.top)
		delete(small.bottom)
	}
	testing.expect_value(t, small.cols, 6)
	testing.expect_value(t, small.rows, 2)
}

@(test)
test_transparent_pixels_become_black :: proc(t: ^testing.T) {
	rgba := []u8{255, 255, 255, 0, 255, 255, 255, 0}
	pic := picture_scale(rgba, 1, 2, 4, 4)
	defer {
		delete(pic.top)
		delete(pic.bottom)
	}
	testing.expect_value(t, pic.top[0], Pixel{0, 0, 0})
}

@(test)
test_a_picture_row_is_half_blocks_in_two_colours :: proc(t: ^testing.T) {
	pic := picture_decode(RED_OVER_BLUE_PNG[:], 56, 14)
	defer {
		delete(pic.top)
		delete(pic.bottom)
	}
	segs := picture_row(pic, 1)
	defer delete(segs)
	testing.expect_value(t, len(segs), 2)
	testing.expect_value(t, segs[0].text, "▀")
	testing.expect_value(t, segs[0].style.fg, tui.color_rgb(0, 0, 255))
	testing.expect_value(t, segs[0].style.bg, tui.color_rgb(0, 0, 255))
}

