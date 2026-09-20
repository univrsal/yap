package clipboard

import "base:runtime"
import "core:encoding/endian"
import "core:testing"
import stbi "vendor:stb/image"

@(private = "file")
append_bytes :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
	context = (^Test_Buffer)(ctx).ctx
	append(&(^Test_Buffer)(ctx).buf, ..([^]u8)(data)[:size])
}

@(private = "file")
Test_Buffer :: struct {
	ctx: runtime.Context,
	buf: [dynamic]u8,
}

// 3x2 RGBA: red, green, blue / white, black, half-transparent grey.
@(private = "file")
TEST_PIXELS := [?]u8 {
	255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,
	255, 255, 255, 255,   0, 0, 0, 255,   128, 128, 128, 128,
}

@(private = "file")
test_png :: proc() -> [dynamic]u8 {
	tb := Test_Buffer{ctx = context}
	stbi.write_png_to_func(append_bytes, &tb, 3, 2, 4, &TEST_PIXELS[0], 3 * 4)
	return tb.buf
}

@(test)
test_decode_png :: proc(t: ^testing.T) {
	png := test_png()
	defer delete(png)
	img, err := decode(png[:])
	defer image_destroy(&img)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, img.width, 3)
	testing.expect_value(t, img.height, 2)
	testing.expect(t, len(img.pixels) == len(TEST_PIXELS))
	for b, i in TEST_PIXELS {
		testing.expect_value(t, img.pixels[i], b)
	}
}

@(test)
test_decode_limits :: proc(t: ^testing.T) {
	png := test_png()
	defer delete(png)
	// Claim 10000x10000 in the IHDR chunk; the size check comes before
	// any decoding (and stb_image doesn't check the chunk's CRC).
	endian.unchecked_put_u32be(png[16:], 10000)
	endian.unchecked_put_u32be(png[20:], 10000)
	_, err := decode(png[:])
	testing.expect_value(t, err, Error.Too_Large)

	garbage := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	_, err = decode(garbage[:])
	testing.expect_value(t, err, Error.Decode_Failed)
	_, err = decode(nil)
	testing.expect_value(t, err, Error.Decode_Failed)
}

// A DIB the way Windows puts one on the clipboard: BITMAPINFOHEADER,
// optional masks, then rows bottom to top, padded to 4 bytes.
@(private = "file")
make_dib :: proc(bits: int, bitfields: bool) -> [dynamic]u8 {
	w, h := 3, 2
	row := ((w * bits / 8) + 3) &~ 3
	dib := make([dynamic]u8, 40)
	endian.unchecked_put_u32le(dib[0:], 40)
	endian.unchecked_put_u32le(dib[4:], u32(w))
	endian.unchecked_put_u32le(dib[8:], u32(h)) // positive: bottom-up
	endian.unchecked_put_u16le(dib[12:], 1)
	endian.unchecked_put_u16le(dib[14:], u16(bits))
	endian.unchecked_put_u32le(dib[16:], 3 if bitfields else 0)
	endian.unchecked_put_u32le(dib[20:], u32(row * h))
	if bitfields {
		masks: [12]u8
		endian.unchecked_put_u32le(masks[0:], 0x00ff0000)
		endian.unchecked_put_u32le(masks[4:], 0x0000ff00)
		endian.unchecked_put_u32le(masks[8:], 0x000000ff)
		append(&dib, ..masks[:])
	}
	for y := h - 1; y >= 0; y -= 1 {
		start := len(dib)
		for x in 0 ..< w {
			p := TEST_PIXELS[(y * w + x) * 4:]
			append(&dib, p[2], p[1], p[0]) // BGR
			if bits == 32 {
				append(&dib, 0) // unused, as most apps leave it
			}
		}
		for len(dib) - start < row {
			append(&dib, 0)
		}
	}
	return dib
}

@(test)
test_dib_to_bmp :: proc(t: ^testing.T) {
	for c in ([]struct {
			bits:      int,
			bitfields: bool,
		}{{24, false}, {32, false}, {32, true}}) {
		dib := make_dib(c.bits, c.bitfields)
		defer delete(dib)
		bmp, err := dib_to_bmp(dib[:])
		defer delete(bmp)
		testing.expect_value(t, err, Error.None)
		img, decode_err := decode(bmp)
		defer image_destroy(&img)
		testing.expectf(t, decode_err == .None, "%d-bit (bitfields %v): %v", c.bits, c.bitfields, decode_err)
		if decode_err != .None {
			continue
		}
		testing.expect_value(t, img.width, 3)
		testing.expect_value(t, img.height, 2)
		// Colors match (and come out top row first); the DIB has no alpha,
		// so it's opaque.
		for i in 0 ..< 6 {
			for ch in 0 ..< 3 {
				testing.expectf(
					t,
					img.pixels[i * 4 + ch] == TEST_PIXELS[i * 4 + ch],
					"%d-bit pixel %d channel %d: %d != %d",
					c.bits,
					i,
					ch,
					img.pixels[i * 4 + ch],
					TEST_PIXELS[i * 4 + ch],
				)
			}
			testing.expect_value(t, img.pixels[i * 4 + 3], 255)
		}
	}

	short := [?]u8{40, 0, 0, 0}
	_, err := dib_to_bmp(short[:])
	testing.expect_value(t, err, Error.Decode_Failed)
}
