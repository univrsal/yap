package client

import "core:fmt"
import "core:strings"
import "core:sync"

import "client:conn"
import glfw "client:wglfw"
import "common:proto"

/*
Pokes (src/common/proto/poke.odin): someone nudging us, shown as a desktop
notification. That goes through the tray icon, which is how traycon
reaches the desktop's notification service; a web build uses the
browser's own. Without either, the Log tab has the poke (the network
side logs it) and the window asks for attention, which is what a
taskbar shows.

Poking someone is in their menu (user_menu). Being mentioned
(conn/mentions.odin), and a call coming in (ui_calls.odin), are told the
same way. They're told from every server, not only the one shown, and
where there are several, which one's it is.
*/

/*
session_notices tells of what a server has for us since the last frame:
pokes, mentions of us (in a conversation being read too, but not a
muted one: conv_new_message), and a call coming in (once). With `named`, the server's name goes with it. Between frames,
with no View locked.
*/
session_notices :: proc(ui: ^UI, ns: ^Net_Session, named: bool) {
	v := &ns.view
	busy: bool
	server, caller: string
	call: proto.Call_Id
	{
		sync.guard(&v.mutex)
		busy = v.my_activity == .Busy
		name := v.server_name if v.server_name != "" else ns.server
		server = strings.clone(name, context.temp_allocator)
		switch v.call.status {
		case .Ringing_In:
			call = v.call.id
			caller = strings.clone(call_peer_name(v), context.temp_allocator)
		case .None:
			ns.call_announced = 0
		case .Ringing_Out, .Active:
		}
	}
	on := fmt.tprintf(" on %s", server) if named else ""
	for p in conn.view_take_pokes(v) {
		// Busy: kept quiet (ui_activity.odin); it's in the log.
		if busy {
			continue
		}
		notice(ui, fmt.tprintf("%s poked you%s", p.name, on), p.message)
	}
	for m in conn.view_take_mentions(v) {
		notice(
			ui,
			fmt.tprintf("%s mentioned you in %s%s", m.name, m.place, on),
			conn.markdown_plain(m.text),
		)
	}
	if call != 0 && call != ns.call_announced {
		ns.call_announced = call
		notice(
			ui,
			fmt.tprintf("%s is calling you%s", caller, on),
			"Answer it in yap.",
			attention = true,
		)
	}
}

// notice puts something on the desktop; without a way to, or with
// `attention`, the window asks for it too.
@(private = "file")
notice :: proc(ui: ^UI, title, body: string, attention := false) {
	if (!tray_notify(ui, title, body) || attention) && ui.window != nil {
		glfw.RequestWindowAttention(ui.window)
	}
}
