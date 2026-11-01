#+build wasi
package ui

import "core"

// A page never sees keys pressed in other windows, so a browser has no
// global hotkeys (see ui/hotkeys_native.odin).

UI_Hotkeys :: struct {}

hotkeys_frame :: proc(ui: ^UI) {}

hotkeys_stop :: proc(ui: ^UI) {}

hotkey_settings :: proc(ui: ^UI) {}

hotkey_text :: proc(env: ^core.Env, deafen: bool) -> string {
	return ""
}
