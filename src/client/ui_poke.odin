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
(conn/mentions.odin), a DM (unless it's being read: dm_open), and a call
coming in (ui_calls.odin), are told the same way. They're told from
every server, not only the one shown, and where there are several, which
one's it is.
*/

/*
session_notices tells of what a server has for us since the last frame:
pokes, mentions of us (in a conversation being read too, but not a
muted one: conv_new_message), DMs, and a call coming in (once). With `named`, the server's name goes with it. Between frames,
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
		if m.dm && dm_open(ui, ns, m.conv) {
			continue
		}
		title := fmt.tprintf("%s mentioned you in %s%s", m.name, m.place, on)
		if m.dm {
			title = fmt.tprintf("%s messaged you%s", m.name, on)
		}
		notice(
			ui,
			title,
			conn.markdown_plain(m.text),
			target = {ui = ui, ns = ns, conv = m.conv, msg = m.msg},
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

/*
dm_open is whether a DM is being read, so a message in it needn't be told
on the desktop: it's the conversation drawn last frame, in the window,
which has the focus. Wayland doesn't say which window has it, so there
being open is enough.
*/
@(private = "file")
dm_open :: proc(ui: ^UI, ns: ^Net_Session, conv: proto.Conv_Id) -> bool {
	st := &ui.timeline
	if ui.window == nil || ui.hidden || st.open != conv || st.open_to != rawptr(ns) {
		return false
	}
	return on_wayland() || ALWAYS_FOCUSED || glfw.WindowFocused(ui.window)
}

// Notice_Target is where clicking a notification goes: the message that
// caused it, if there is one, on the server (session) it came from.
Notice_Target :: struct {
	ui:   ^UI,
	ns:   ^Net_Session,
	conv: proto.Conv_Id,
	msg:  proto.Msg_Id,
}

// notice_open goes to what a clicked notification was about, if that's
// a message and its server is still there.
notice_open :: proc(ui: ^UI, target: Notice_Target) {
	if target.msg == 0 {
		return
	}
	for ns in ui.sessions {
		if ns == target.ns && !ns.joining {
			show_session(ui, ns)
			sync.guard(&ui.view.mutex)
			go_to_message(ui, target.conv, target.msg)
			ui_redraw(ui)
			return
		}
	}
}

// notice puts something on the desktop; without a way to, or with
// `attention`, the window asks for it too.
@(private = "file")
notice :: proc(ui: ^UI, title, body: string, attention := false, target := Notice_Target{}) {
	if (!tray_notify(ui, title, body, target) || attention) && ui.window != nil {
		glfw.RequestWindowAttention(ui.window)
	}
}
