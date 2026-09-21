package client

import "core:fmt"

import glfw "wglfw"

/*
Pokes (proto/poke.odin): someone nudging us, shown as a desktop
notification. That goes through the tray icon, which is how traycon
reaches the desktop's notification service; a web build uses the
browser's own. Without either, the Log tab has the poke (the network
side logs it) and the window asks for attention, which is what a
taskbar shows.

Poking someone is in their menu (user_menu).
*/

// show_pokes shows what's come in since the last frame.
show_pokes :: proc(ui: ^UI) {
	for p in view_take_pokes(&ui.view) {
		title := fmt.tprintf("%s poked you", p.name)
		if !tray_notify(ui, title, p.message) && ui.window != nil {
			glfw.RequestWindowAttention(ui.window)
		}
	}
}
