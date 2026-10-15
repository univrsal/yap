#+build wasi
package clipboard

// A web build has no libwebp. The browser decodes its pictures, including
// WebP (see web/decode.js and src/client/ui_images_worker_web.odin), so
// nothing ever reaches this procedure.
@(private)
decode_webp :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	return {}, .Decode_Failed
}
