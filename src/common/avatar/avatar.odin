#+build !wasi
package avatar

import "base:runtime"
import stbi "vendor:stb/image"

import "common:proto"
import log "common:wlog"

// Profile pictures: any picture made into the one that yap keeps, the largest
// centered square scaled down to at most MAX_AVATAR_SIDE and compressed to a
// JPEG of at most MAX_AVATAR_SIZE. The client makes its users' own pictures
// like this (client/imaging), and the importer those of a Mattermost server.

// decode reads a picture (JPEG, PNG, GIF or BMP: what stb_image reads) into
// RGBA pixels. The pixels belong to stb_image: free them with
// stbi.image_free.
decode :: proc(data: []u8) -> (width, height: int, pixels: []u8, ok: bool) {
	if len(data) == 0 || len(data) > 1 << 30 {
		return
	}
	w, h, channels: i32
	raw := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if raw == nil || w <= 0 || h <= 0 {
		return
	}
	return int(w), int(h), raw[:int(w) * int(h) * 4], true
}

// flatten drops the alpha channel of RGBA pixels by compositing them onto
// white. `rgb` has room for 3 bytes a pixel.
flatten :: proc(width, height: int, pixels, rgb: []u8) {
	for i in 0 ..< width * height {
		p := pixels[i * 4:]
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

// encode_jpeg compresses RGB pixels (3 bytes each) to a JPEG.
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

// prepare makes a profile picture from RGBA pixels: the largest centered
// square, scaled down to at most `max_side` and compressed to fit `max_size`.
// The quality is lowered until it fits (a picture that small always fits at
// some quality). A server's picture is made the same way but smaller (see
// proto.MAX_SERVER_ICON_SIDE).
prepare :: proc(
	width, height: int,
	pixels: []u8,
	allocator := context.allocator,
	max_side := proto.MAX_AVATAR_SIDE,
	max_size := proto.MAX_AVATAR_SIZE,
) -> (
	jpeg: []u8,
	side: int,
	ok: bool,
) {
	if width <= 0 || height <= 0 || len(pixels) < width * height * 4 {
		return
	}
	full := min(width, height)
	x0, y0 := (width - full) / 2, (height - full) / 2
	square := make([]u8, full * full * 4)
	defer delete(square)
	for y in 0 ..< full {
		row := ((y0 + y) * width + x0) * 4
		copy(square[y * full * 4:][:full * 4], pixels[row:][:full * 4])
	}
	rgb := make([]u8, full * full * 3)
	defer delete(rgb)
	flatten(full, full, square, rgb)

	out := min(full, max_side)
	scaled := rgb
	if out != full {
		scaled = make([]u8, out * out * 3)
		if stbi.resize_uint8_srgb(
			   raw_data(rgb),
			   i32(full),
			   i32(full),
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
			return
		}
	}
	defer if out != full {
		delete(scaled)
	}
	for quality: i32 = 88; quality >= 30; quality -= 12 {
		data, encoded := encode_jpeg(scaled, out, out, quality, allocator)
		if !encoded {
			return
		}
		if len(data) <= max_size {
			log.debugf("picture: %dx%d, quality %d, %d bytes", out, out, quality, len(data))
			return data, out, true
		}
		delete(data, allocator)
	}
	log.error("could not compress the picture small enough")
	return
}

// from_bytes makes a profile picture from the bytes of a picture file.
from_bytes :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	jpeg: []u8,
	side: int,
	ok: bool,
) {
	width, height, pixels, decoded := decode(data)
	if !decoded {
		return
	}
	defer stbi.image_free(raw_data(pixels))
	return prepare(width, height, pixels, allocator)
}
