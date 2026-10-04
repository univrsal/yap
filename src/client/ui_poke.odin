package client

import "core:fmt"
import "core:sync"

import glfw "client:wglfw"
import "client:conn"

/*
Pokes (src/common/proto/poke.odin): someone nudging us, shown as a desktop
notification. That goes through the tray icon, which is how traycon
reaches the desktop's notification service; a web build uses the
browser's own. Without either, the Log tab has the poke (the network
side logs it) and the window asks for attention, which is what a
taskbar shows.

Poking someone is in their menu (user_menu). Being mentioned
(conn/mentions.odin) is told the same way.
*/

// show_pokes shows what's come in since the last frame: pokes, and
// mentions of us (which the network side only passes on when the
// conversation isn't being read, and may interrupt).
show_pokes :: proc(ui: ^UI) {
	busy: bool
	{
		sync.guard(&ui.view.mutex)
		busy = ui.view.my_activity == .Busy
	}
	for p in conn.view_take_pokes(&ui.view) {
		// Busy: kept quiet (ui_activity.odin); it's in the log.
		if busy {
			continue
		}
		title := fmt.tprintf("%s poked you", p.name)
		if !tray_notify(ui, title, p.message) && ui.window != nil {
			glfw.RequestWindowAttention(ui.window)
		}
	}
	for m in conn.view_take_mentions(&ui.view) {
		title := fmt.tprintf("%s mentioned you in %s", m.name, m.place)
		if !tray_notify(ui, title, conn.markdown_plain(m.text)) && ui.window != nil {
			glfw.RequestWindowAttention(ui.window)
		}
	}
}
