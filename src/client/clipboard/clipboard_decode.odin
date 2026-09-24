package clipboard

import log "../../common/wlog"
import stbi "../wstbi"

// decode turns PNG, JPEG, BMP or GIF data into RGBA pixels, refusing
// images over MAX_PIXELS before decoding them.
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	if len(data) == 0 || len(data) > MAX_DATA_SIZE {
		return {}, .Decode_Failed if len(data) == 0 else .Too_Large
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
