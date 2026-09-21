#+build wasi
package client

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// A browser notification, if the page may show them (web/shell.c).
	yap_notify :: proc(title, body: cstring) -> b32 ---
}

/*
A page has no system tray to put an icon in, and its window is a tab:
closing it closes the page. So in a web build there is no tray, the
window is never hidden, and the settings that decide what closing and
minimizing do aren't shown (see ui_settings.odin).
*/

Tray :: struct {}

tray_update :: proc(ui: ^UI) {}
tray_hide :: proc(ui: ^UI) {}
tray_takes_window :: proc(ui: ^UI, setting: bool) -> bool {return false}
hide_to_tray :: proc(ui: ^UI) {}
show_from_tray :: proc(ui: ^UI) {}
on_wayland :: proc() -> bool {return false}

// tray_notify is a browser notification here: there's no tray, but the
// browser has its own, once the user has allowed it (see web/shell.c).
tray_notify :: proc(ui: ^UI, title, body: string) -> bool {
	return bool(
		yap_notify(
			strings.clone_to_cstring(title, context.temp_allocator),
			strings.clone_to_cstring(body, context.temp_allocator),
		),
	)
}
