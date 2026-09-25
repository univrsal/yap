#+build wasi
package client

// A page never sees keys pressed in other windows, so a browser has no
// global hotkeys (see ui_hotkeys_native.odin).

UI_Hotkeys :: struct {}

hotkeys_frame :: proc(ui: ^UI) {}

hotkeys_stop :: proc(ui: ^UI) {}

hotkey_settings :: proc(ui: ^UI) {}
