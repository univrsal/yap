#+build wasi
package client

/*
Saving a picture means a download in a browser, which the page starts
and the browser finishes - there's no path to hand back. Since pictures
can't be shown in a web build yet either (see
clipboard/clipboard_decode_web.odin), there's nothing to save.
*/
save_to_downloads :: proc(
	data: []u8,
	ext: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	return "", false
}
