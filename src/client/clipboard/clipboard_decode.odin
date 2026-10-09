package clipboard

import stbi "client:wstbi"
import log "common:wlog"
import "core:bytes"
import "core:encoding/endian"
import "core:image/qoi"

// decode turns PNG, JPEG, BMP, GIF, WebP or QOI data into RGBA pixels,
// refusing images over MAX_PIXELS before decoding them. (QOI is what a
// server's sheet of emoji comes as: core Odin writes it, and stb_image
// doesn't read it. Nor does it read WebP, which libwebp does; see
// webp_decode.odin.)
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	if len(data) == 0 || len(data) > MAX_DATA_SIZE {
		return {}, .Decode_Failed if len(data) == 0 else .Too_Large
	}
	if is_qoi(data) {
		return decode_qoi(data, allocator)
	}
	// RIFF, a size, WEBP.
	if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return decode_webp(data, allocator)
	}
	w, h, comp: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp) == 0 {
		log.debugf("clipboard: can't decode the image: %s", stbi.failure_reason())
		return {}, .Decode_Failed
	}
	if w <= 0 || h <= 0 || i64(w) * i64(h) > MAX_PIXELS {
		log.debugf("clipboard: image is %dx%d, over the limit", w, h)
		return {}, .Too_Large
	}
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
	if pixels == nil {
		log.debugf("clipboard: can't decode the image: %s", stbi.failure_reason())
		return {}, .Decode_Failed
	}
	defer stbi.image_free(pixels)
	n := int(w) * int(h) * 4
	img = {
		width  = int(w),
		height = int(h),
		pixels = make([]u8, n, allocator),
	}
	copy(img.pixels, pixels[:n])
	return img, .None
}

// is_qoi is whether `data` is a QOI picture, which decode reads itself
// (a web build hands everything else to the browser).
is_qoi :: proc(data: []u8) -> bool {
	return len(data) > 14 && string(data[:4]) == "qoif"
}

@(private = "file")
decode_qoi :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	w := endian.unchecked_get_u32be(data[4:])
	h := endian.unchecked_get_u32be(data[8:])
	if w == 0 || h == 0 || i64(w) * i64(h) > MAX_PIXELS {
		return {}, .Too_Large
	}
	q, qerr := qoi.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if qerr != nil || q == nil || q.channels != 4 || q.depth != 8 {
		log.debugf("clipboard: can't decode the QOI: %v", qerr)
		return {}, .Decode_Failed
	}
	pixels := bytes.buffer_to_bytes(&q.pixels)
	img = {
		width  = q.width,
		height = q.height,
		pixels = make([]u8, len(pixels), allocator),
	}
	copy(img.pixels, pixels)
	return img, .None
}
