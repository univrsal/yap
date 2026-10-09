#+build !wasi
package clipboard

import log "common:wlog"

import "client:webp"

// decode_webp is decode for a WebP picture, which stb_image can't read:
// libwebp (client:webp) decodes it straight into the result. Only a still
// picture; an animation is refused.
@(private)
decode_webp :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	w, h, ok := webp.size(data)
	if !ok {
		log.debug("clipboard: can't decode the WebP")
		return {}, .Decode_Failed
	}
	if w <= 0 || h <= 0 || i64(w) * i64(h) > MAX_PIXELS {
		log.debugf("clipboard: image is %dx%d, over the limit", w, h)
		return {}, .Too_Large
	}
	img = {
		width  = w,
		height = h,
		pixels = make([]u8, w * h * 4, allocator),
	}
	if !webp.decode_into(data, img.pixels, w) {
		log.debug("clipboard: can't decode the WebP (an animation?)")
		delete(img.pixels, allocator)
		return {}, .Decode_Failed
	}
	return img, .None
}
