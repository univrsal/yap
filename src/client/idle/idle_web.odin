#+build wasi
package idle

import "core:time"

@(private = "file", default_calling_convention = "c")
foreign _ {
	// The Idle Detection API (see web/shell.c).
	yap_idle_web_open :: proc(after_ms: i32) ---
	// 1 idle, 0 not, -1 not running (no API, or no permission yet).
	yap_idle_web_check :: proc() -> i32 ---
	// 1 if the API is there but the page hasn't been allowed to use it.
	yap_idle_web_can_ask :: proc() -> i32 ---
	yap_idle_web_ask :: proc() ---
	yap_idle_web_close :: proc() ---
}

// open starts the detector if the page already has the permission; the
// browser keeps that once given, so it's only asked for once (ask).
open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	yap_idle_web_open(i32(clamp(time.duration_milliseconds(after), 0, f64(max(i32)))))
	return .Browser
}

check :: proc() -> (idle: bool, known: bool) {
	r := yap_idle_web_check()
	return r == 1, r >= 0
}

// can_ask says whether there's a permission to ask for: the API is
// there and the page isn't allowed (or refused) yet.
can_ask :: proc() -> bool {
	return yap_idle_web_can_ask() == 1
}

// ask asks for the permission, and starts the detector if it's given.
// Only from a click: the browser wants the user to have just done
// something.
ask :: proc() {
	yap_idle_web_ask()
}

close :: proc() {
	yap_idle_web_close()
}
