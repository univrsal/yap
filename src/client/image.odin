#+build !wasi
package client

import "base:runtime"
import log "common:wlog"
import "core:math"
import "core:os"
import stbi "vendor:stb/image"

import "client:clipboard"
import "client:conn"
import "common:webp"
import "common:proto"

/*
Turning a pasted image (RGBA, see clipboard) into something worth
sending: scaled to at most 4K on its longest side, and WebP compressed
to fit a size budget. A screenshot comes out at well under half the size
JPEG needs for the same quality, so most fit at full size. (Profile and
server pictures are still JPEGs, which the server checks they are; see
avatar_prepare.)

Transparent parts are put on white, the way a screenshot of a page would
look, so dark text on nothing stays readable on a dark theme.

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
// What a pasted image may take up, compressed: a screenshot uploads in
// a moment, and its preview is fetched as quickly.
MAX_IMAGE_BYTES :: 256 * 1024
// WebP quality for the first try, for the second (same size), and for
// the tries after that (which shrink the image instead). 80 is a little
// sharper than the JPEG at 85 this used to make, at half the size.
QUALITY_FIRST :: 80
QUALITY_SECOND :: 60
QUALITY_SCALED :: 70
// libwebp's trade of speed for size, 0 to 6: 2 compresses twice as fast
// as its default of 4, for files about 4% bigger.
WEBP_METHOD :: 2
// How often to shrink and try again before giving up.
MAX_SCALE_ROUNDS :: 4


// image_prepare scales and compresses a pasted image, to attach.
image_prepare :: proc(
	src: clipboard.Image,
	allocator := context.allocator,
) -> (
	img: conn.Chat_Image,
	ok: bool,
) {
	if src.width <= 0 || src.height <= 0 || len(src.pixels) < src.width * src.height * 4 {
		return {}, false
	}
	// On white (see above). These buffers are large (24 MB for a 4K
	// image), so they aren't left for the temporary allocator to hold on
	// to.
	rgb := make([]u8, src.width * src.height * 3)
	defer delete(rgb)
	flatten(src, rgb)

	w, h := fit(src.width, src.height, MAX_IMAGE_SIDE)
	quality: f32 = QUALITY_FIRST
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

		data, encoded := webp.encode(scaled, w, h, quality, WEBP_METHOD, allocator)
		if !encoded {
			log.error("could not compress the image")
			return {}, false
		}
		if len(data) <= MAX_IMAGE_BYTES {
			log.debugf("image: %dx%d, quality %.0f, %d bytes", w, h, quality, len(data))
			return {jpeg = data, width = w, height = h}, true
		}
		log.debugf(
			"image: %dx%d, quality %.0f is %d bytes, over the budget",
			w,
			h,
			quality,
			len(data),
		)
		over := len(data)
		delete(data, allocator)

		if round == 0 {
			quality = QUALITY_SECOND // same size, cheaper bits first
			continue
		}
		if w <= 64 || h <= 64 || round > MAX_SCALE_ROUNDS {
			// It should never come to this: even a 64x64 picture is tiny.
			log.error("could not compress the image small enough")
			return {}, false
		}
		// A picture's size roughly follows its pixel count, so scale by the
		// square root of how far over budget it was, and a little more so
		// the next try lands inside rather than just on the line.
		quality = QUALITY_SCALED
		factor := clamp(0.95 * math.sqrt(f64(MAX_IMAGE_BYTES) / f64(over)), 0.25, 0.9)
		w, h = max(int(f64(w) * factor), 1), max(int(f64(h) * factor), 1)
	}
	return {}, false
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
encode_jpeg :: proc(
	rgb: []u8,
	w, h: int,
	quality: i32,
	allocator := context.allocator,
) -> (
	jpeg: []u8,
	ok: bool,
) {
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

/*
avatar_prepare makes a profile picture of an image: the largest square
from its centre, scaled down to at most `max_side`, and compressed to
fit `max_size` (quality is lowered till it does; a picture that small
always does at some quality). A server's picture is made the same way,
smaller (proto.MAX_SERVER_ICON_SIDE).
*/
avatar_prepare :: proc(
	src: clipboard.Image,
	allocator := context.allocator,
	max_side := proto.MAX_AVATAR_SIDE,
	max_size := proto.MAX_AVATAR_SIZE,
) -> (
	img: conn.Chat_Image,
	ok: bool,
) {
	if src.width <= 0 || src.height <= 0 || len(src.pixels) < src.width * src.height * 4 {
		return {}, false
	}
	side := min(src.width, src.height)
	x0, y0 := (src.width - side) / 2, (src.height - side) / 2
	square := make([]u8, side * side * 4)
	defer delete(square)
	for y in 0 ..< side {
		row := ((y0 + y) * src.width + x0) * 4
		copy(square[y * side * 4:][:side * 4], src.pixels[row:][:side * 4])
	}
	rgb := make([]u8, side * side * 3)
	defer delete(rgb)
	flatten({width = side, height = side, pixels = square}, rgb)

	out := min(side, max_side)
	scaled := rgb
	if out != side {
		scaled = make([]u8, out * out * 3)
		if stbi.resize_uint8_srgb(
			   raw_data(rgb),
			   i32(side),
			   i32(side),
			   0,
			   raw_data(scaled),
			   i32(out),
			   i32(out),
			   0,
			   3,
			   stbi.ALPHA_CHANNEL_NONE,
			   0,
		   ) ==
		   0 {
			delete(scaled)
			log.error("could not scale the picture")
			return {}, false
		}
	}
	defer if out != side {
		delete(scaled)
	}
	for quality: i32 = 88; quality >= 30; quality -= 12 {
		jpeg := encode_jpeg(scaled, out, out, quality, allocator) or_return
		if len(jpeg) <= max_size {
			log.debugf("picture: %dx%d, quality %d, %d bytes", out, out, quality, len(jpeg))
			return {jpeg = jpeg, width = out, height = out}, true
		}
		delete(jpeg, allocator)
	}
	log.error("could not compress the picture small enough")
	return {}, false
}

// avatar_load makes a profile picture of an image file, as
// avatar_prepare does.
avatar_load :: proc(
	path: string,
	allocator := context.allocator,
	max_side := proto.MAX_AVATAR_SIDE,
	max_size := proto.MAX_AVATAR_SIZE,
) -> (
	img: conn.Chat_Image,
	ok: bool,
) {
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
	return avatar_prepare(decoded, allocator, max_side, max_size)
}
