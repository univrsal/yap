#+build wasi
package idle

import "core:time"

@(private = "file", default_calling_convention = "c")
foreign _ {
	// The Idle Detection API (see web/shell.c).
	yap_idle_web_open :: proc(after_ms: i32) ---
	// 1 if idle, 0 if not, -1 if not running (no API, or no permission yet).
	yap_idle_web_check :: proc() -> i32 ---
	// 1 if the API exists but the page hasn't been allowed to use it yet.
	yap_idle_web_can_ask :: proc() -> i32 ---
	yap_idle_web_ask :: proc() ---
	yap_idle_web_close :: proc() ---
}

// open starts the detector if the page already has the permission. The browser
// remembers the permission once it is granted, so it only has to be asked for
// once (ask).
open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	yap_idle_web_open(i32(clamp(time.duration_milliseconds(after), 0, f64(max(i32)))))
	return .Browser
}

check :: proc() -> (idle: bool, known: bool) {
	r := yap_idle_web_check()
	return r == 1, r >= 0
}

// can_ask reports whether there is a permission to ask for: the API exists and
// the page has neither been allowed nor refused yet.
can_ask :: proc() -> bool {
	return yap_idle_web_can_ask() == 1
}

// ask asks for the permission, and starts the detector if it is granted. Only
// call it from a click handler: the browser requires a recent user action.
ask :: proc() {
	yap_idle_web_ask()
}

close :: proc() {
	yap_idle_web_close()
}
