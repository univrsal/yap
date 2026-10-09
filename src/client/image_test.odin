#+build !wasi
package client

import "core:testing"
import stbi "vendor:stb/image"

import "client:clipboard"
import "client:conn"
import "client:webp"
import "common:proto"

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
	defer conn.chat_image_destroy(&img)
	testing.expect(t, ok)
	testing.expect_value(t, img.width, 200)
	testing.expect_value(t, img.height, 100)
	testing.expect(t, len(img.jpeg) <= MAX_IMAGE_BYTES)

	// It's a WebP of the right size.
	testing.expect(t, webp.is_webp(img.jpeg))
	w, h, size_ok := webp.size(img.jpeg)
	testing.expect(t, size_ok)
	testing.expect_value(t, w, 200)
	testing.expect_value(t, h, 100)

	// And it reads back as what was pasted.
	back, err := clipboard.decode(img.jpeg)
	defer clipboard.image_destroy(&back)
	testing.expect_value(t, err, clipboard.Error.None)
	testing.expect(t, back.width == 200 && back.height == 100)
	testing.expect_value(t, len(back.pixels), 200 * 100 * 4)
}

@(test)
test_webp_decode :: proc(t: ^testing.T) {
	// A smooth image survives lossy compression nearly as it was.
	src := gradient_image(64, 32)
	defer delete(src.pixels)
	rgb := make([]u8, 64 * 32 * 3)
	defer delete(rgb)
	for i in 0 ..< 64 * 32 {
		copy(rgb[i * 3:][:3], src.pixels[i * 4:][:3])
	}
	data, ok := webp.encode(rgb, 64, 32, 90)
	defer delete(data)
	testing.expect(t, ok)

	img, err := clipboard.decode(data)
	defer clipboard.image_destroy(&img)
	testing.expect_value(t, err, clipboard.Error.None)
	testing.expect(t, img.width == 64 && img.height == 32)
	worst := 0
	for i in 0 ..< 64 * 32 {
		for c in 0 ..< 3 {
			worst = max(worst, abs(int(img.pixels[i * 4 + c]) - int(src.pixels[i * 4 + c])))
		}
		testing.expect_value(t, img.pixels[i * 4 + 3], 255) // opaque
	}
	testing.expectf(t, worst < 24, "a channel is off by %d", worst)

	// Broken data is refused rather than read past.
	_, bad := clipboard.decode(data[:len(data) / 2])
	testing.expect_value(t, bad, clipboard.Error.Decode_Failed)
	_, bad = clipboard.decode(transmute([]u8)string("RIFF\x04\x00\x00\x00WEBPVP8 "))
	testing.expect_value(t, bad, clipboard.Error.Decode_Failed)
}

@(test)
test_image_scaled_to_4k :: proc(t: ^testing.T) {
	// A smooth image compresses well, so it only loses what the 4K limit
	// takes off.
	src := gradient_image(5000, 400)
	defer delete(src.pixels)
	img, ok := image_prepare(src)
	defer conn.chat_image_destroy(&img)
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
	defer conn.chat_image_destroy(&img)
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
	defer conn.chat_image_destroy(&img)
	testing.expect(t, ok)

	back, err := clipboard.decode(img.jpeg)
	defer clipboard.image_destroy(&back)
	testing.expect_value(t, err, clipboard.Error.None)
	// The transparent first row came out white, not black. Lossy
	// compression bleeds the noise below it into the row, so it isn't
	// exactly 255.
	for x in 0 ..< back.width {
		for c in 0 ..< 3 {
			testing.expectf(
				t,
				back.pixels[x * 4 + c] > 200,
				"pixel %d channel %d is %d",
				x,
				c,
				back.pixels[x * 4 + c],
			)
		}
	}
}

@(test)
test_image_rejects_bad_input :: proc(t: ^testing.T) {
	_, ok := image_prepare({})
	testing.expect(t, !ok)
	_, ok = image_prepare(
		{width = 10, height = 10, pixels = make([]u8, 4, context.temp_allocator)},
	)
	testing.expect(t, !ok)
}

@(test)
test_avatar_prepare :: proc(t: ^testing.T) {
	// A wide photo: the middle square, scaled to the largest picture,
	// within the budget even when it's noisy.
	src := test_image(1200, 600)
	defer delete(src.pixels)
	img, ok := avatar_prepare(src)
	defer conn.chat_image_destroy(&img)
	testing.expect(t, ok)
	testing.expect_value(t, img.width, 256)
	testing.expect_value(t, img.height, 256)
	testing.expect(t, len(img.jpeg) <= 64 * 1024)
	w, h, comp: i32
	testing.expect(
		t,
		stbi.info_from_memory(raw_data(img.jpeg), i32(len(img.jpeg)), &w, &h, &comp) == 1,
	)
	testing.expect(t, w == 256 && h == 256)

	noisy := gradient_image(900, 900)
	defer delete(noisy.pixels)
	big, big_ok := avatar_prepare(noisy)
	defer conn.chat_image_destroy(&big)
	testing.expect(t, big_ok && len(big.jpeg) <= 64 * 1024)

	// A small tall one isn't grown, only cut square.
	small := test_image(40, 80)
	defer delete(small.pixels)
	tiny, tiny_ok := avatar_prepare(small)
	defer conn.chat_image_destroy(&tiny)
	testing.expect(t, tiny_ok)
	testing.expect(t, tiny.width == 40 && tiny.height == 40)

	_, bad := avatar_prepare({})
	testing.expect(t, !bad)

	// A server's picture: smaller, and fits in one response.
	icon, icon_ok := avatar_prepare(
		noisy,
		max_side = proto.MAX_SERVER_ICON_SIDE,
		max_size = proto.MAX_SERVER_ICON_SIZE,
	)
	defer conn.chat_image_destroy(&icon)
	testing.expect(t, icon_ok)
	testing.expect(t, icon.width == proto.MAX_SERVER_ICON_SIDE && icon.height == icon.width)
	testing.expect(t, len(icon.jpeg) <= proto.MAX_SERVER_ICON_SIZE)
}
