#+build wasi
package clipboard

/*
stb_image has no build for wasm in the vendor collection, and a browser
can decode a picture perfectly well itself - it just can't do it here
and now, since createImageBitmap hands its result back later. Until the
web build has somewhere to put that, a picture arrives and is marked as
one we can't show.
*/
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	return {}, .Decode_Failed
}
