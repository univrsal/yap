#+build wasi
package client

// Choosing a picture isn't there in a browser yet (ui_avatar_pick_native.odin).

Avatar_Pick :: struct {}

avatar_pick_start :: proc(ui: ^UI, paste: bool) {}
avatar_pick_poll :: proc(ui: ^UI) {}
avatar_pick_wait :: proc(ui: ^UI) {}
