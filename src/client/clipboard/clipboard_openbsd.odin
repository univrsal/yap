package clipboard

import log "common:wlog"

// OpenBSD's desktops use X11, so that is the only backend here. The Wayland
// display passed to init is always nil.

@(private = "file")
have_x11: bool

_init :: proc(wayland_display: rawptr) -> bool {
	have_x11 = x11_init()
	if !have_x11 {
		log.warn("clipboard: images can't be pasted (no X11 clipboard access)")
	}
	return have_x11
}

_destroy :: proc() {
	if have_x11 {
		x11_destroy()
	}
	have_x11 = false
}

_read_encoded :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	if !have_x11 {
		return nil, "", .Unavailable
	}
	return x11_read(allocator)
}
