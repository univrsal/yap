#+build !wasi
package imagekind

import "core:testing"

// The size of each kind of picture is read from its header, and a header
// that is cut short or isn't a picture's has none.
@(test)
test_dimensions :: proc(t: ^testing.T) {
	Case :: struct {
		name:          string,
		data:          []u8,
		width, height: int,
	}
	cases := []Case {
		{
			"png",
			{
				0x89,
				'P',
				'N',
				'G',
				'\r',
				'\n',
				0x1a,
				'\n',
				0,
				0,
				0,
				13,
				'I',
				'H',
				'D',
				'R',
				0,
				0,
				0x07,
				0x80,
				0,
				0,
				0x04,
				0x38,
			},
			1920,
			1080,
		},
		{"gif", {'G', 'I', 'F', '8', '9', 'a', 0x40, 0x01, 0xf0, 0x00}, 320, 240},
		{
			"webp lossy",
			{
				'R',
				'I',
				'F',
				'F',
				0,
				0,
				0,
				0,
				'W',
				'E',
				'B',
				'P',
				'V',
				'P',
				'8',
				' ',
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0x9d,
				0x01,
				0x2a,
				0x80,
				0x02,
				0xe0,
				0x01,
			},
			640,
			480,
		},
		{
			// 640x480: 639 | 479 << 14 = 0x0077c27f
			"webp lossless",
			{
				'R',
				'I',
				'F',
				'F',
				0,
				0,
				0,
				0,
				'W',
				'E',
				'B',
				'P',
				'V',
				'P',
				'8',
				'L',
				0,
				0,
				0,
				0,
				0x2f,
				0x7f,
				0xc2,
				0x77,
				0x00,
				0,
				0,
				0,
				0,
				0,
			},
			640,
			480,
		},
		{
			"webp extended",
			{
				'R',
				'I',
				'F',
				'F',
				0,
				0,
				0,
				0,
				'W',
				'E',
				'B',
				'P',
				'V',
				'P',
				'8',
				'X',
				0,
				0,
				0,
				0,
				0x10,
				0,
				0,
				0,
				0x7f,
				0x02,
				0x00,
				0xdf,
				0x01,
				0x00,
			},
			640,
			480,
		},
		{
			// Stored top-down, so with a negative height.
			"bmp",
			{
				'B',
				'M',
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				40,
				0,
				0,
				0,
				0x64,
				0,
				0,
				0,
				0xce,
				0xff,
				0xff,
				0xff,
			},
			100,
			50,
		},
		{
			"jpeg",
			{
				0xff,
				0xd8,
				0xff,
				0xe0,
				0,
				4,
				0,
				0,
				0xff,
				0xc0,
				0,
				11,
				8,
				0x01,
				0x2c,
				0x01,
				0x90,
				3,
				0,
				0,
				0,
			},
			400,
			300,
		},
		{
			"png cut short",
			{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0},
			0,
			0,
		},
		{"text", transmute([]u8)string("just some text, not a picture at all"), 0, 0},
	}
	for c in cases {
		w, h, ok := dimensions(c.data)
		testing.expectf(t, ok == (c.width > 0), "%s: ok is %v", c.name, ok)
		testing.expectf(t, w == c.width && h == c.height, "%s: %dx%d", c.name, w, h)
	}
}

@(test)
test_stbi_readable :: proc(t: ^testing.T) {
	testing.expect(t, stbi_readable([]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0}))
	testing.expect(t, stbi_readable([]u8{0xFF, 0xD8, 0xFF, 0xE0, 0, 0}))
	testing.expect(t, stbi_readable(transmute([]u8)string("GIF89a\x01\x00\x01\x00")))
	testing.expect(
		t,
		stbi_readable(
			transmute([]u8)string(
				"BM\x1e\x00\x00\x00\x00\x00\x00\x00\x1a\x00\x00\x00\x0c\x00\x00\x00",
			),
		),
	)
	// What stb_image also reads, and what isn't a picture.
	testing.expect(t, !stbi_readable(transmute([]u8)string("P6\n1 1\n255\n\x01\x02\x03")))
	testing.expect(t, !stbi_readable(transmute([]u8)string("#?RADIANCE\n")))
	testing.expect(t, !stbi_readable(transmute([]u8)string("8BPS\x00\x01")))
	testing.expect(t, !stbi_readable(transmute([]u8)string("BM")))
	testing.expect(t, !stbi_readable(nil))
}

@(test)
test_jpeg_orientation :: proc(t: ^testing.T) {
	// SOI, APP1 with a TIFF whose first directory has one entry, the
	// orientation, then a start of scan.
	jpeg :: proc(order: string, value: u8) -> []u8 {
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, 0xff, 0xd8, 0xff, 0xe1, 0, 34)
		append(&b, 'E', 'x', 'i', 'f', 0, 0)
		append(&b, order[0], order[1])
		if order == "II" {
			append(&b, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, value, 0, 0, 0)
		} else {
			append(&b, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, value, 0, 0)
		}
		append(&b, 0, 0, 0, 0, 0xff, 0xda)
		return b[:]
	}
	testing.expect_value(t, jpeg_orientation(jpeg("II", 6)), 6)
	testing.expect_value(t, jpeg_orientation(jpeg("MM", 8)), 8)
	testing.expect_value(t, jpeg_orientation(jpeg("II", 9)), 1)
	testing.expect_value(t, jpeg_orientation(jpeg("MM", 0)), 1)
	// Cut off inside the directory, not a JPEG, and no metadata at all.
	testing.expect_value(t, jpeg_orientation(jpeg("II", 6)[:20]), 1)
	testing.expect_value(t, jpeg_orientation(transmute([]u8)string("hello")), 1)
	testing.expect_value(t, jpeg_orientation({0xff, 0xd8, 0xff, 0xda, 0, 2}), 1)
}

@(test)
test_orient :: proc(t: ^testing.T) {
	// 3 wide, 2 tall; each pixel's first byte says which it is.
	pixels := make([]u8, 3 * 2 * 4, context.temp_allocator)
	for i in 0 ..< 6 {
		pixels[i * 4] = u8(i)
	}
	// Orientation 6 turns it a quarter clockwise: 2 wide, 3 tall, and what was
	// the bottom-left pixel (3) is now the top-left.
	out, w, h := orient_rgba(pixels, 3, 2, 6)
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 3)
	first := [6]u8{3, 0, 4, 1, 5, 2}
	for want, i in first {
		testing.expect_value(t, out[i * 4], want)
	}
	// 3 is upside down, 2 is mirrored, and 1 is left as it is.
	delete(out)
	out, w, h = orient_rgba(pixels, 3, 2, 3)
	testing.expect_value(t, w, 3)
	for want, i in ([6]u8{5, 4, 3, 2, 1, 0}) {
		testing.expect_value(t, out[i * 4], want)
	}
	delete(out)
	out, _, _ = orient_rgba(pixels, 3, 2, 2)
	for want, i in ([6]u8{2, 1, 0, 5, 4, 3}) {
		testing.expect_value(t, out[i * 4], want)
	}
	delete(out)
	out, _, _ = orient_rgba(pixels, 3, 2, 1)
	testing.expect(t, raw_data(out) == raw_data(pixels))
}

@(test)
test_jpeg_orientation_of_a_file :: proc(t: ^testing.T) {
	jpeg := #load("testdata/turned.jpg")
	testing.expect_value(t, jpeg_orientation(jpeg), 6)
	w, h, ok := dimensions(jpeg)
	testing.expect(t, ok)
	// The header states the size it is stored at.
	testing.expect_value(t, w, 64)
	testing.expect_value(t, h, 32)
}
