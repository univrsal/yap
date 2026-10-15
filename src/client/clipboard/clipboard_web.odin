#+build wasi
package clipboard

// The browser's clipboard works very differently from a desktop's: a page
// can only read it from inside a paste event, and only if the user triggered
// the paste. That doesn't fit the "read the clipboard now" model that the
// rest of this package uses, so a web build reports that there is nothing to
// read, and the paste path is switched off above it (see ui_paste.odin).
//
// Text still works, because the canvas receives copy and paste through GLFW
// like any other key press.

_init :: proc(wayland_display: rawptr) -> bool {
	return true
}

_destroy :: proc() {}

_read_encoded :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	return nil, "", .Unavailable
}
