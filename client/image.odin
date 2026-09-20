package client

import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import stbi "vendor:stb/image"

import "clipboard"

/*
Turning a pasted image (RGBA, see clipboard) into something worth
sending: scaled to at most 4K on its longest side, and JPEG compressed
to fit a size budget.

JPEG has no transparency, so transparent parts are put on white, the
way a screenshot of a page would look.

Quality is lowered before the image is made smaller: a slightly softer
screenshot is more readable than a sharp half-size one. Only when the
low quality still doesn't fit does it shrink, and then by how much the
last attempt missed the budget by, rather than in fixed steps, so as
little resolution as possible is given up.

A screenshot usually fits on the first try; the rounds after it are for
photos and noisy images, which compress far worse.
*/

// The longest side an image keeps; bigger images are scaled down.
MAX_IMAGE_SIDE :: 3840
// What a chat image may take up, compressed.
MAX_IMAGE_BYTES :: 256 * 1024
// Quality for the first try, for the second (same size), and for the
// tries after that (which shrink the image instead).
QUALITY_FIRST :: 85
QUALITY_SECOND :: 60
QUALITY_SCALED :: 75
// How often to shrink and try again before giving up.
MAX_SCALE_ROUNDS :: 4

Chat_Image :: struct {
	jpeg:          []u8, // owned
	width, height: int, // after scaling
}

chat_image_destroy :: proc(img: ^Chat_Image, allocator := context.allocator) {
	delete(img.jpeg, allocator)
	img^ = {}
}

// image_load prepares an image file (PNG, JPEG, ...) the same way a
// pasted one is prepared.
image_load :: proc(path: string, allocator := context.allocator) -> (img: Chat_Image, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("could not read %s: %v", path, err)
		return {}, false
	}
	decoded, decode_err := clipboard.decode(data, context.temp_allocator)
	if decode_err != .None {
		log.errorf("could not read the image in %s: %v", path, decode_err)
		return {}, false
	}
	defer clipboard.image_destroy(&decoded, context.temp_allocator)
	return image_prepare(decoded, allocator)
}

// image_prepare scales and compresses a pasted image for sending.
image_prepare :: proc(src: clipboard.Image, allocator := context.allocator) -> (img: Chat_Image, ok: bool) {
	if src.width <= 0 || src.height <= 0 || len(src.pixels) < src.width * src.height * 4 {
		return {}, false
	}
	// On white, without the alpha channel JPEG can't store anyway. These
	// buffers are large (24 MB for a 4K image), so they aren't left for
	// the temporary allocator to hold on to.
	rgb := make([]u8, src.width * src.height * 3)
	defer delete(rgb)
	flatten(src, rgb)

	w, h := fit(src.width, src.height, MAX_IMAGE_SIDE)
	quality: i32 = QUALITY_FIRST
	for round in 0 ..= MAX_SCALE_ROUNDS + 1 {
		scaled := rgb
		defer if raw_data(scaled) != raw_data(rgb) {
			delete(scaled)
		}
		if w != src.width || h != src.height {
			scaled = make([]u8, w * h * 3)
			if stbi.resize_uint8_srgb(
				   raw_data(rgb),
				   i32(src.width),
				   i32(src.height),
				   0,
				   raw_data(scaled),
				   i32(w),
				   i32(h),
				   0,
				   3,
				   stbi.ALPHA_CHANNEL_NONE,
				   0,
			   ) ==
			   0 {
				log.error("could not scale the image")
				return {}, false
			}
		}

		jpeg := encode_jpeg(scaled, w, h, quality, allocator) or_return
		if len(jpeg) <= MAX_IMAGE_BYTES {
			log.debugf("image: %dx%d, quality %d, %d bytes", w, h, quality, len(jpeg))
			return {jpeg = jpeg, width = w, height = h}, true
		}
		log.debugf("image: %dx%d, quality %d is %d bytes, over the budget", w, h, quality, len(jpeg))
		over := len(jpeg)
		delete(jpeg, allocator)

		if round == 0 {
			quality = QUALITY_SECOND // same size, cheaper bits first
			continue
		}
		if w <= 64 || h <= 64 || round > MAX_SCALE_ROUNDS {
			// It should never come to this: even a 64x64 JPEG is tiny.
			log.error("could not compress the image small enough")
			return {}, false
		}
		// A JPEG's size roughly follows its pixel count, so scale by the
		// square root of how far over budget it was, and a little more so
		// the next try lands inside rather than just on the line.
		quality = QUALITY_SCALED
		factor := clamp(0.95 * math.sqrt(f64(MAX_IMAGE_BYTES) / f64(over)), 0.25, 0.9)
		w, h = max(int(f64(w) * factor), 1), max(int(f64(h) * factor), 1)
	}
	return {}, false
}

// fit_box shrinks (never grows) width and height to fit a rectangle,
// keeping the shape of the image.
fit_box :: proc(width, height, max_w, max_h: int) -> (w, h: int) {
	if width <= 0 || height <= 0 {
		return max_w, max_h
	}
	w, h = width, height
	if w > max_w {
		w, h = max_w, max(height * max_w / width, 1)
	}
	if h > max_h {
		w, h = max(w * max_h / h, 1), max_h
	}
	return w, h
}

// fit shrinks (never grows) width and height to fit a square of `side`.
fit :: proc(width, height, side: int) -> (w, h: int) {
	if width <= side && height <= side {
		return width, height
	}
	if width >= height {
		return side, max(height * side / width, 1)
	}
	return max(width * side / height, 1), side
}

// flatten drops the alpha channel, putting the image on white.
@(private = "file")
flatten :: proc(src: clipboard.Image, rgb: []u8) {
	for i in 0 ..< src.width * src.height {
		p := src.pixels[i * 4:]
		a := int(p[3])
		for c in 0 ..< 3 {
			// Rounded (c * a + 255 * (255 - a)) / 255.
			v := int(p[c]) * a + 255 * (255 - a)
			rgb[i * 3 + c] = u8((v + 127) / 255)
		}
	}
}

@(private = "file")
Jpeg_Writer :: struct {
	ctx: runtime.Context,
	buf: [dynamic]u8,
}

@(private = "file")
encode_jpeg :: proc(rgb: []u8, w, h: int, quality: i32, allocator := context.allocator) -> (jpeg: []u8, ok: bool) {
	writer := Jpeg_Writer {
		ctx = context,
		buf = make([dynamic]u8, 0, 64 * 1024, allocator),
	}
	write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		w := (^Jpeg_Writer)(ctx)
		context = w.ctx
		append(&w.buf, ..([^]u8)(data)[:size])
	}
	if stbi.write_jpg_to_func(write, &writer, i32(w), i32(h), 3, raw_data(rgb), quality) == 0 {
		log.error("could not compress the image")
		delete(writer.buf)
		return nil, false
	}
	return writer.buf[:], true
}
