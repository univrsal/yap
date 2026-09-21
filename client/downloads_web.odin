#+build wasi
package client

/*
Saving a picture means a download in a browser, which the page starts
and the browser finishes - there's no path to hand back. Until the page
can start one, a web build doesn't save pictures.
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
