#+build freebsd, openbsd, netbsd
package idle

import "core:time"

// GLFW's X11 connection isn't reachable from here on the BSDs, so the
// client goes by its own window's input alone.

open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	return .None
}

check :: proc() -> (idle: bool, known: bool) {
	return false, false
}

close :: proc() {}
