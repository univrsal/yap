package client

import "core:fmt"
import "core:strings"
import "core:sync"

import "client:conn"
import "client:richtext"
import glfw "client:wglfw"
import "common:proto"

// Notices are desktop notifications for being mentioned (richtext/mentions.odin),
// for a DM (unless it is being read: dm_open) and for an incoming call
// (ui_calls.odin). They go through the tray icon, which is how traycon reaches
// the desktop's notification service. A web build uses the browser's own
// notifications. If neither is available, the window asks for attention
// instead, which a taskbar shows. Notices are shown for every server, not only
// the one that is shown, and when there are several servers the notice says
// which one it came from. In a web build with push enabled and the page out of
// sight, the server's push notifications report mentions and DMs instead
// (see ui_push_web.odin).

// session_notices shows notices for what a server has for us since the last
// frame: mentions of us (also in a conversation that is being read, but not in
// a muted one: conv_new_message), DMs, and an incoming call (only once). With
// `named`, the server's name is included. Call between frames, with no View
// locked.
session_notices :: proc(ui: ^UI, ns: ^Net_Session, named: bool) {
	v := &ns.view
	server, caller: string
	call: proto.Call_Id
	{
		sync.guard(&v.mutex)
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
	pushed := push_covers(ns)
	for m in conn.view_take_mentions(v) {
		if pushed || (m.dm && dm_open(ui, ns, m.conv)) {
			continue
		}
		title := fmt.tprintf("%s mentioned you in %s%s", m.name, m.place, on)
		if m.dm {
			title = fmt.tprintf("%s messaged you%s", m.name, on)
		}
		notice(
			ui,
			title,
			richtext.markdown_plain(m.text),
			target = {ui = ui, ns = ns, conv = m.conv, msg = m.msg},
		)
	}
	if call != 0 && call != ns.call_announced && !pushed {
		ns.call_announced = call
		notice(
			ui,
			fmt.tprintf("%s is calling you%s", caller, on),
			"Answer it in yap.",
			attention = true,
		)
	}
}

// dm_open is whether a DM is being read, so that a new message in it needs no
// desktop notification. That is the case when it is the conversation drawn
// last frame in a window that has the focus. Wayland doesn't say which window
// has the focus, so having the DM open is enough there.
@(private = "file")
dm_open :: proc(ui: ^UI, ns: ^Net_Session, conv: proto.Conv_Id) -> bool {
	st := &ui.timeline
	if ui.window == nil || ui.hidden || st.open != conv || st.open_to != rawptr(ns) {
		return false
	}
	return on_wayland() || ALWAYS_FOCUSED || glfw.WindowFocused(ui.window)
}

// Notice_Target is where clicking a notification leads: the message that
// caused it, if there is one, on the server (session) it came from.
Notice_Target :: struct {
	ui:   ^UI,
	ns:   ^Net_Session,
	conv: proto.Conv_Id,
	msg:  proto.Msg_Id,
}

// notice_open goes to what a clicked notification was about, if that is a
// message and its server still exists.
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

// notice shows something on the desktop. If there is no way to do that, or
// with `attention`, the window asks for attention too.
@(private = "file")
notice :: proc(ui: ^UI, title, body: string, attention := false, target := Notice_Target{}) {
	if (!tray_notify(ui, title, body, target) || attention) && ui.window != nil {
		glfw.RequestWindowAttention(ui.window)
	}
}
