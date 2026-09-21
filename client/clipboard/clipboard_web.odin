#+build wasi
package clipboard

/*
The browser's clipboard is nothing like a desktop's: a page can only
read it from inside a paste event, and only if the user made the paste
happen. That doesn't fit the "ask for the clipboard now" shape the rest
of this package has, so a web build reports there's nothing to read and
the paste path is switched off above it (see ui_paste.odin).

Text still works, because the canvas gets copy and paste through GLFW
like any other key press.
*/

_init :: proc(wayland_display: rawptr) -> bool {
	return true
}

_destroy :: proc() {}

_read_encoded :: proc(
	allocator := context.allocator,
) -> (
	data: []u8,
	mime: string,
	err: Error,
) {
	return nil, "", .Unavailable
}
