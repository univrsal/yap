#+build wasi
package client

import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import glfw "client:wglfw"
import "common:proto"

@(default_calling_convention = "c")
foreign _ {
	// Web Push, implemented in web/push.js and exposed through web/shell.c.
	yap_push_state :: proc(server: cstring) -> i32 ---
	yap_push_check :: proc(server: cstring, key: [^]u8) ---
	yap_push_enable :: proc(server: cstring, key: [^]u8) ---
	yap_push_disable :: proc(server: cstring) ---
	yap_push_take :: proc(server: cstring, endpoint: [^]u8, size: i32, p256dh: [^]u8, auth: [^]u8) -> i32 ---
	yap_push_take_unsubscribe :: proc(server: cstring) -> b32 ---
	yap_push_seen :: proc(server: cstring, conv: u32) ---
	yap_push_take_open :: proc(server: [^]u8, size: i32, conv: ^u32, msg: ^f64) -> i32 ---
	yap_page_hidden :: proc() -> b32 ---
	yap_set_badge :: proc(n: i32) ---
}

// Web Push (docs/design/mobile.md): once push is enabled in the account settings, a server that
// supports it (View.server_push) can notify this browser about DMs and mentions while the
// page is closed or in the background. This goes through the browser's push service and a
// service worker (web/sw.js). The browser creates the subscription (web/push.js); the UI
// code here starts that, passes the subscription to the server (conn/push.odin), opens the
// conversation of a tapped notification, and removes a conversation's notification once
// it has been read here.
//
// Whether push is enabled for a server is tracked by the browser alone; none of it is
// stored in the client's settings.
//
// An installed web app also shows a badge on its icon with the number of unread DMs and
// mentions across all servers (web/push.js).

// The push state that web/push.js reports for a server.
Push_State :: enum i32 {
	Unsupported,
	Off,
	Working,
	On,
	Blocked,
	Failed,
	Home_Screen, // a Safari tab on iOS: only an app added to the home screen can use push
}

// The conversation of a tapped notification, kept until its server is connected and
// ready to show it.
@(private = "file")
g_pending_open: struct {
	server: string, // owned
	conv:   proto.Conv_Id,
	msg:    proto.Msg_Id,
}

// The conversation that was last read here, so that its notification is removed only once.
@(private = "file")
g_last_seen: struct {
	ns:   ^Net_Session,
	conv: proto.Conv_Id,
}

// page_hidden reports whether the page is currently not visible.
page_hidden :: proc() -> bool {
	return bool(yap_page_hidden())
}

// push_covers reports whether a push notification already covers what the session would
// show as a desktop notification: push is enabled for it and the page is hidden, so the
// server sends a push, and a notification from the page as well would be a duplicate.
push_covers :: proc(ns: ^Net_Session) -> bool {
	return page_hidden() && Push_State(yap_push_state(server_cstring(ns))) == .On
}

// push_frame does the per-frame push work: for each server that supports push and that
// we're logged in to, it asks the browser for the current subscription state, and sends
// the server any subscription the browser created or dropped. It also opens the
// conversation of a tapped notification and removes the notification of the
// conversation that is currently being read.
push_frame :: proc(ui: ^UI) {
	for ns in ui.sessions {
		key, pushes := session_push_key(ns)
		if !pushes || !session_ready(ns) {
			continue
		}
		server := server_cstring(ns)
		if !ns.push_checked || ns.push_key != key {
			ns.push_checked, ns.push_key = true, key
			yap_push_check(server, &key[0])
		}
		endpoint: [proto.MAX_PUSH_ENDPOINT + 1]u8
		sub: proto.Push_Subscription
		if n := yap_push_take(
			server,
			&endpoint[0],
			i32(len(endpoint)),
			&sub.p256dh[0],
			&sub.auth[0],
		); n > 0 {
			sub.endpoint = strings.clone(string(endpoint[:n]))
			conn.push_command(&ns.client.commands, conn.Push_Subscribe_Command{sub})
		}
		if yap_push_take_unsubscribe(server) {
			conn.push_command(&ns.client.commands, conn.Push_Unsubscribe_Command{})
		}
	}
	push_open_step(ui)

	// The icon badge: the number of unread DMs and mentions (counted by servers_frame),
	// once a server has reported our unread state. Until then, the badge keeps the count
	// the service worker made while the app was closed.
	for ns in ui.sessions {
		if session_ready(ns) {
			yap_set_badge(i32(ui.mentions))
			break
		}
	}

	// A conversation counts as read here when the page is visible and has focus.
	ns := ui.session
	st := &ui.timeline
	if ns == nil ||
	   page_hidden() ||
	   !glfw.WindowFocused(ui.window) ||
	   st.open == 0 ||
	   st.open_to != rawptr(ns) {
		g_last_seen = {}
	} else if g_last_seen.ns != ns || g_last_seen.conv != st.open {
		g_last_seen = {ns, st.open}
		yap_push_seen(server_cstring(ns), u32(st.open))
	}
}

// push_open_step opens the message of a tapped notification, once the notification's
// server is connected and ready to show it.
@(private = "file")
push_open_step :: proc(ui: ^UI) {
	buf: [512]u8
	conv: u32
	msg: f64
	if n := yap_push_take_open(&buf[0], i32(len(buf)), &conv, &msg); n > 0 {
		delete(g_pending_open.server)
		g_pending_open = {strings.clone(string(buf[:n])), proto.Conv_Id(conv), proto.Msg_Id(msg)}
	}
	if g_pending_open.server == "" {
		return
	}
	for ns in ui.sessions {
		if ns.server != g_pending_open.server || ns.joining {
			continue
		}
		if !session_ready(ns) {
			return // not ready yet, try again next frame
		}
		show_session(ui, ns)
		sync.lock(&ui.view.mutex)
		go_to_message(ui, g_pending_open.conv, g_pending_open.msg)
		sync.unlock(&ui.view.mutex)
		ui_redraw(ui)
		break
	}
	delete(g_pending_open.server)
	g_pending_open = {}
}

// push_settings draws the account settings rows for push on this device, if the server
// supports push: whether push is enabled on this device (stored by the browser), and
// whether pushes include the message text (an account setting, proto.SETTING_PUSH_TEXT).
// Call with the View locked.
push_settings :: proc(ui: ^UI, v: ^conn.View) {
	ns := ui.session
	if !v.server_push || !v.shared_synced || ns == nil {
		return
	}
	state := Push_State(yap_push_state(server_cstring(ns)))
	if state == .Unsupported {
		return
	}
	ctx := &ui.ctx
	field_row(ui, FORM_LABEL, "Push notifications", {CHOICE_WIDTH})
	on := state == .On
	at := -1 if state == .Working else int(on)
	can := state == .Off || state == .Failed
	if i, ok := choice_dropdown(ui, "push", {"Off", "On this device"}, at, none = "Updating...");
	   ok {
		if i == 0 && on {
			yap_push_disable(server_cstring(ns))
		} else if i == 1 && can {
			key := v.server_push_key
			yap_push_enable(server_cstring(ns), &key[0])
		}
	}
	hint: string
	switch state {
	case .Unsupported, .Off:
		hint = "Get notified about DMs and mentions while yap is closed or in the background."
	case .Working:
		hint = "Updating push notifications..."
	case .On:
		hint = "DMs and mentions are pushed to this device while yap is closed or in the background."
	case .Blocked:
		hint = "This browser blocks notifications from yap. Allow them in the browser's site settings."
	case .Failed:
		hint = "Enabling push notifications failed. The browser's console has the details."
	case .Home_Screen:
		hint = "On an iPhone or iPad, add yap to the home screen (Share, Add to Home Screen) and turn this on there."
	}
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	with_text_color(ctx, theme.dim, hint, wrap_text)

	hidden := (v.shared[proto.SETTING_PUSH_TEXT] or_else "") == proto.PUSH_TEXT_HIDDEN
	field_row(ui, FORM_LABEL, "Pushes contain", {CHOICE_WIDTH})
	if i, ok := choice_dropdown(ui, "push text", {"Message text", "Only the sender"}, int(hidden));
	   ok {
		conn.push_command(
			&ns.client.commands,
			conn.Setting_Command {
				key = strings.clone(proto.SETTING_PUSH_TEXT),
				value = strings.clone("" if i == 0 else proto.PUSH_TEXT_HIDDEN),
			},
		)
	}
}

// session_ready reports whether a session is logged in and has received its settings.
@(private = "file")
session_ready :: proc(ns: ^Net_Session) -> bool {
	v := &ns.view
	sync.guard(&v.mutex)
	return v.status == .Connected && v.shared_synced
}

// session_push_key returns the server's VAPID key, and whether the server supports push.
@(private = "file")
session_push_key :: proc(ns: ^Net_Session) -> (key: [proto.PUSH_KEY_SIZE]u8, pushes: bool) {
	v := &ns.view
	sync.guard(&v.mutex)
	return v.server_push_key, v.server_push
}

@(private = "file")
server_cstring :: proc(ns: ^Net_Session) -> cstring {
	return strings.clone_to_cstring(ns.server, context.temp_allocator)
}
