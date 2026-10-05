#+build linux
package idle

import "core:time"

LIB :: "libyap_idle.a"

when !#exists(LIB) {
	#panic("src/client/idle/" + LIB + " is missing; build it with build.sh")
}

foreign import lib {LIB, "system:dl"}

@(private = "file", default_calling_convention = "c")
foreign lib {
	yap_idle_open :: proc(wayland_display, x11_display: rawptr, after_ms: u32) -> i32 ---
	yap_idle_check :: proc() -> i32 ---
	yap_idle_close :: proc() ---
}

// open starts watching for `after` without input, on whichever of the
// window's displays GLFW has (the other is nil).
open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	ms := u32(clamp(time.duration_milliseconds(after), 0, f64(max(u32))))
	switch yap_idle_open(wayland_display, x11_display, ms) {
	case 1:
		return .Wayland
	case 2:
		return .X11
	}
	return .None
}

check :: proc() -> (idle: bool, known: bool) {
	r := yap_idle_check()
	return r == 1, r >= 0
}

close :: proc() {
	yap_idle_close()
}
