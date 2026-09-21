#+build wasi
package client

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
