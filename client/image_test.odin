package client

import "core:testing"
import stbi "vendor:stb/image"

import "clipboard"

// test_image makes a w*h RGBA image: noise (so it doesn't compress to
// nothing) with an alpha ramp across the first rows.
@(private = "file")
test_image :: proc(w, h: int, alpha: bool = false) -> clipboard.Image {
	pixels := make([]u8, w * h * 4)
	seed: u32 = 12345
	for i in 0 ..< w * h {
		seed = seed * 1664525 + 1013904223
		pixels[i * 4 + 0] = u8(seed >> 16)
		pixels[i * 4 + 1] = u8(seed >> 8)
		pixels[i * 4 + 2] = u8(seed)
		pixels[i * 4 + 3] = 255
	}
	if alpha {
		for x in 0 ..< w {
			pixels[x * 4 + 0] = 0
			pixels[x * 4 + 1] = 0
			pixels[x * 4 + 2] = 0
			pixels[x * 4 + 3] = 0 // fully transparent black
		}
	}
	return {width = w, height = h, pixels = pixels}
}

// gradient_image is a smooth image, which compresses well.
@(private = "file")
gradient_image :: proc(w, h: int) -> clipboard.Image {
	pixels := make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			pixels[i + 0] = u8(x * 255 / max(w - 1, 1))
			pixels[i + 1] = u8(y * 255 / max(h - 1, 1))
			pixels[i + 2] = 128
			pixels[i + 3] = 255
		}
	}
	return {width = w, height = h, pixels = pixels}
}

@(test)
test_fit :: proc(t: ^testing.T) {
	w, h := fit(100, 50, 3840)
	testing.expect_value(t, w, 100) // never grows
	testing.expect_value(t, h, 50)
	w, h = fit(7680, 4320, 3840)
	testing.expect_value(t, w, 3840)
	testing.expect_value(t, h, 2160)
	w, h = fit(1000, 8000, 3840)
	testing.expect_value(t, w, 480)
	testing.expect_value(t, h, 3840)
	w, h = fit(10000, 2, 3840)
	testing.expect_value(t, w, 3840)
	testing.expect_value(t, h, 1) // never zero
}

@(test)
test_image_prepare :: proc(t: ^testing.T) {
	src := test_image(200, 100)
	defer delete(src.pixels)
	img, ok := image_prepare(src)
	defer chat_image_destroy(&img)
	testing.expect(t, ok)
	testing.expect_value(t, img.width, 200)
	testing.expect_value(t, img.height, 100)
	testing.expect(t, len(img.jpeg) <= MAX_IMAGE_BYTES)

	// It's a JPEG of the right size.
	w, h, comp: i32
	testing.expect(t, stbi.info_from_memory(raw_data(img.jpeg), i32(len(img.jpeg)), &w, &h, &comp) != 0)
	testing.expect_value(t, w, 200)
	testing.expect_value(t, h, 100)
	testing.expect(t, img.jpeg[0] == 0xff && img.jpeg[1] == 0xd8) // SOI marker
}

@(test)
test_image_scaled_to_4k :: proc(t: ^testing.T) {
	// A smooth image compresses well, so it only loses what the 4K limit
	// takes off.
	src := gradient_image(5000, 400)
	defer delete(src.pixels)
	img, ok := image_prepare(src)
	defer chat_image_destroy(&img)
	testing.expect(t, ok)
	testing.expect_value(t, img.width, MAX_IMAGE_SIDE)
	testing.expect_value(t, img.height, 307) // 400 * 3840 / 5000
	testing.expectf(t, len(img.jpeg) <= MAX_IMAGE_BYTES, "%d bytes", len(img.jpeg))
}

@(test)
test_image_scaled_to_fit_budget :: proc(t: ^testing.T) {
	// Noise can't be compressed, so it has to shrink past 4K as well,
	// keeping its shape.
	src := test_image(5000, 400)
	defer delete(src.pixels)
	img, ok := image_prepare(src)
	defer chat_image_destroy(&img)
	testing.expect(t, ok)
	testing.expectf(t, len(img.jpeg) <= MAX_IMAGE_BYTES, "%d bytes", len(img.jpeg))
	testing.expect(t, img.width <= MAX_IMAGE_SIDE && img.height <= MAX_IMAGE_SIDE)
	testing.expect(t, img.width < MAX_IMAGE_SIDE) // it had to shrink further
	ratio := f64(img.width) / f64(img.height)
	testing.expectf(t, abs(ratio - 12.5) < 0.2, "aspect ratio %.2f", ratio)
}

@(test)
test_image_transparency :: proc(t: ^testing.T) {
	src := test_image(64, 64, alpha = true)
	defer delete(src.pixels)
	img, ok := image_prepare(src)
	defer chat_image_destroy(&img)
	testing.expect(t, ok)

	w, h, comp: i32
	pixels := stbi.load_from_memory(raw_data(img.jpeg), i32(len(img.jpeg)), &w, &h, &comp, 3)
	testing.expect(t, pixels != nil)
	defer stbi.image_free(pixels)
	// The transparent first row came out white, not black. JPEG bleeds
	// the noise below it into the row, so it isn't exactly 255.
	for x in 0 ..< int(w) {
		for c in 0 ..< 3 {
			testing.expectf(t, pixels[x * 3 + c] > 200, "pixel %d channel %d is %d", x, c, pixels[x * 3 + c])
		}
	}
}

@(test)
test_image_rejects_bad_input :: proc(t: ^testing.T) {
	_, ok := image_prepare({})
	testing.expect(t, !ok)
	_, ok = image_prepare({width = 10, height = 10, pixels = make([]u8, 4, context.temp_allocator)})
	testing.expect(t, !ok)
}
