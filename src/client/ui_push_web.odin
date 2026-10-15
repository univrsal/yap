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
	// Web Push (web/push.js, through web/shell.c).
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

/*
Web Push (misc/mobile): a server that pushes (View.server_push) can tell
this browser about DMs and mentions while the page is closed or out of
sight, through the browser's push service and a service worker
(web/sw.js), once it's turned on in the account's settings. The browser
does the subscribing (web/push.js); here the UI starts it, hands the
subscription to the server (conn/push.odin), goes where a tapped
notification says, and takes a conversation's notification down once
it's read here.

Whether it's on is the browser's to know, for each server: nothing of
it is in the client's settings.

An installed app also gets a number on its icon: unread DMs and
mentions, from every server (web/push.js).
*/

// What web/push.js says of a server.
Push_State :: enum i32 {
	Unsupported,
	Off,
	Working,
	On,
	Blocked,
	Failed,
	Home_Screen, // an iPhone's Safari tab: only the home screen's app can
}

// A tapped notification's conversation, until its server is there to
// show it.
@(private = "file")
pending_open: struct {
	server: string, // owned
	conv:   proto.Conv_Id,
	msg:    proto.Msg_Id,
}

// What was last read here, so its notification is taken down once.
@(private = "file")
last_seen: struct {
	ns:   ^Net_Session,
	conv: proto.Conv_Id,
}

// page_hidden is whether the page is out of sight.
page_hidden :: proc() -> bool {
	return bool(yap_page_hidden())
}

/*
push_covers is whether a push tells of what a session would put on the
desktop: push is on for it and the page is out of sight, so the server
pushes, and a notice from the page too would say it twice.
*/
push_covers :: proc(ns: ^Net_Session) -> bool {
	return page_hidden() && Push_State(yap_push_state(server_cstring(ns))) == .On
}

/*
push_frame does push's part of a frame: asks the browser what it has
for each server that pushes, once logged in there; gives each server
what the browser subscribed or dropped; shows what a tapped notification
was about; and takes down the notification of what's being read.
*/
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
		if n := yap_push_take(server, &endpoint[0], i32(len(endpoint)), &sub.p256dh[0], &sub.auth[0]); n > 0 {
			sub.endpoint = strings.clone(string(endpoint[:n]))
			conn.push_command(&ns.client.commands, conn.Push_Subscribe_Command{sub})
		}
		if yap_push_take_unsubscribe(server) {
			conn.push_command(&ns.client.commands, conn.Push_Unsubscribe_Command{})
		}
	}
	push_open_step(ui)

	// The icon's number: unread DMs and mentions (servers_frame counts
	// them), once a server has said what we have unread. Before that it's
	// what the service worker counted while the app was closed.
	for ns in ui.sessions {
		if session_ready(ns) {
			yap_set_badge(i32(ui.mentions))
			break
		}
	}

	// Read here: the page is in sight and has the focus.
	ns := ui.session
	st := &ui.timeline
	if ns == nil || page_hidden() || !glfw.WindowFocused(ui.window) || st.open == 0 || st.open_to != rawptr(ns) {
		last_seen = {}
	} else if last_seen.ns != ns || last_seen.conv != st.open {
		last_seen = {ns, st.open}
		yap_push_seen(server_cstring(ns), u32(st.open))
	}
}

// push_open_step goes where a tapped notification asked, once its
// server is there to show it.
@(private = "file")
push_open_step :: proc(ui: ^UI) {
	buf: [512]u8
	conv: u32
	msg: f64
	if n := yap_push_take_open(&buf[0], i32(len(buf)), &conv, &msg); n > 0 {
		delete(pending_open.server)
		pending_open = {strings.clone(string(buf[:n])), proto.Conv_Id(conv), proto.Msg_Id(msg)}
	}
	if pending_open.server == "" {
		return
	}
	for ns in ui.sessions {
		if ns.server != pending_open.server || ns.joining {
			continue
		}
		if !session_ready(ns) {
			return // not yet
		}
		show_session(ui, ns)
		sync.lock(&ui.view.mutex)
		go_to_message(ui, pending_open.conv, pending_open.msg)
		sync.unlock(&ui.view.mutex)
		ui_redraw(ui)
		break
	}
	delete(pending_open.server)
	pending_open = {}
}

/*
push_settings is the account settings' rows for push on this device, if
the server pushes: on or off here (the browser's), and whether pushes
say what a message says (an account setting, proto.SETTING_PUSH_TEXT).
Call with the View locked.
*/
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
	field_row(ui, FORM_LABEL, "Push notifications", {210, 210})
	on := state == .On
	if choice_button(ui, "push off", "Off", !on && state != .Working) && on {
		yap_push_disable(server_cstring(ns))
	}
	can := state == .Off || state == .Failed
	if choice_button(ui, "push on", "On this device", on) && can {
		key := v.server_push_key
		yap_push_enable(server_cstring(ns), &key[0])
	}
	hint: string
	switch state {
	case .Unsupported, .Off:
		hint = "DMs and mentions, while yap is closed or out of sight."
	case .Working:
		hint = "A moment..."
	case .On:
		hint = "DMs and mentions come to this device while yap is closed or out of sight."
	case .Blocked:
		hint = "This browser blocks yap's notifications: allow them in its site settings."
	case .Failed:
		hint = "That didn't work; the browser's console says why."
	case .Home_Screen:
		hint = "On an iPhone or iPad, add yap to the home screen (Share, Add to Home Screen) and turn this on there."
	}
	mu.layout_row(ctx, {FORM_LABEL, -1})
	mu.label(ctx, "")
	with_text_color(ctx, theme.dim, hint, wrap_text)

	hidden := (v.shared[proto.SETTING_PUSH_TEXT] or_else "") == proto.PUSH_TEXT_HIDDEN
	field_row(ui, FORM_LABEL, "Pushes show", {210, 210})
	if choice_button(ui, "push text shown", "The message", !hidden) && hidden {
		conn.push_command(
			&ns.client.commands,
			conn.Setting_Command{key = strings.clone(proto.SETTING_PUSH_TEXT), value = strings.clone("")},
		)
	}
	if choice_button(ui, "push text hidden", "Only who wrote", hidden) && !hidden {
		conn.push_command(
			&ns.client.commands,
			conn.Setting_Command {
				key = strings.clone(proto.SETTING_PUSH_TEXT),
				value = strings.clone(proto.PUSH_TEXT_HIDDEN),
			},
		)
	}
}

// session_ready is whether a session is logged in and has its settings.
@(private = "file")
session_ready :: proc(ns: ^Net_Session) -> bool {
	v := &ns.view
	sync.guard(&v.mutex)
	return v.status == .Connected && v.shared_synced
}

// session_push_key is the server's VAPID key, if it pushes.
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
