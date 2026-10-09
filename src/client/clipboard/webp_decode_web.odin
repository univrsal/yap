#+build wasi
package clipboard

// A web build has no libwebp: the browser decodes its pictures, WebP
// among them (web/decode.js, src/client/ui_images_worker_web.odin), so
// nothing comes here.
@(private)
decode_webp :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	return {}, .Decode_Failed
}
