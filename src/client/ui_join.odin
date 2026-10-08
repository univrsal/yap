package client

import "client:conn"
import "client:settings"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

/*
Joining a server from the rail's + (docs/next, item 9b): a dialog asks
for its address and password, and connects. The session it makes is
among UI.sessions from then on (its network turns, mute, idle... go to
it as to every other), and shown, but marked `joining`: off the rail,
with the start screen behind the dialog, and not in the settings.

What happens next is the server's to say, and the dialog shows it in
place: a server that knows this device logs it in by itself, and it's
joined - on the rail, in the settings, the dialog gone. One that doesn't
asks for the login screen (with Register where the server allows it),
drawn inside the dialog; one whose key has changed, the trust prompt; a
failed connection, the form again with what went wrong.

Giving up (Cancel, the dialog's close button, a click elsewhere on the
rail) ends the session and shows again what was shown before.
*/

UI_Join :: struct {
	open:         bool,
	placed:       bool, // the window has been put in the middle
	server_buf:   [256]u8,
	server_len:   int,
	password_buf: [proto.MAX_PASSWORD_SIZE]u8,
	password_len: int,
	// The session being joined, the one shown till it's logged in; and
	// the one shown before, to go back to.
	ns:           ^Net_Session,
	back:         ^Net_Session,
	// Asked for in the dialog, done after the frame (join_frame):
	// connecting waits on the network thread, which may be waiting on
	// the View lock.
	connect:      bool,
	close:        bool,
}

@(private = "file")
JOIN_WINDOW :: "Join a server"

// join_open opens the + dialog, empty.
join_open :: proc(ui: ^UI) {
	if ui.join.open {
		return
	}
	ui.join = {
		open = true,
	}
}

/*
join_frame does what the dialog asked for in the last frame, and once
the session it's joining is logged in, puts it on the rail and in the
settings. Between frames, with no View locked.
*/
join_frame :: proc(ui: ^UI) {
	j := &ui.join
	if j.close {
		join_close(ui)
		return
	}
	if j.connect {
		j.connect = false
		join_connect(
			ui,
			string(j.server_buf[:j.server_len]),
			string(j.password_buf[:j.password_len]),
		)
	}
	ns := j.ns
	if ns == nil {
		return
	}
	admitted: bool
	{
		sync.guard(&ns.view.mutex)
		admitted = ns.view.status == .Connected && ns.view.login.state == .Done
	}
	if !admitted {
		return
	}
	log.infof("ui: joined %s", ns.server)
	ns.joining = false
	ui.join = {}
	settings.join_server(&ui.settings, ns.server, ns.password)
	save_settings(ui)
	ui_redraw(ui)
}

/*
join_connect connects the dialog to `server`: a new session, shown, or
one in place of the dialog's last (failed, or with its key just
trusted). A server joined already is shown instead, and the dialog
closed.
*/
join_connect :: proc(ui: ^UI, typed, password: string) {
	server := conn.with_default_port(typed)
	if server == "" {
		return
	}
	for other in ui.sessions {
		if !other.joining && other.server == server {
			join_close(ui)
			show_session(ui, other)
			return
		}
	}
	monitor_stop(ui) // the connection opens the microphone itself
	log.infof("ui: joining %s", server)
	old := ui.join.ns
	ns := session_new(ui, server, password)
	ns.joining = true
	if old == nil {
		ui.join.back = ui.session
		append(&ui.sessions, ns)
	} else {
		for &other in ui.sessions {
			if other == old {
				other = ns
			}
		}
	}
	ui.join.ns = ns
	show_session(ui, ns)
	if old != nil {
		stash_destroy(ui, old)
		session_free(ui, old)
	}
	net_start(ns)
}

// join_close closes the dialog, giving up the session it was joining,
// if any, and showing again the one shown before it. Between frames.
join_close :: proc(ui: ^UI) {
	j := ui.join
	ui.join = {}
	ns := j.ns
	if ns == nil {
		return
	}
	log.infof("ui: not joining %s", ns.server)
	session_remove(ui, ns)
	for other in ui.sessions {
		if other == j.back {
			show_session(ui, other)
		}
	}
	session_free(ui, ns)
}

// join_dialog draws the + dialog, over everything else.
join_dialog :: proc(ui: ^UI, window_w, window_h: i32) {
	j := &ui.join
	if !j.open {
		return
	}
	ctx := &ui.ctx
	// Opened in the middle, as big as a login wants.
	if !j.placed {
		j.placed = true
		w := clamp(window_w - 40, 260, 480)
		h := clamp(window_h - 40, 160, 400)
		if cnt := mu.get_container(ctx, JOIN_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			// The click that opened it would raise the window behind at
			// the end of the frame (see image_viewer).
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if cnt := mu.get_container(ctx, JOIN_WINDOW, {.CLOSED});
	   cnt != nil && cnt.open && cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(ctx, JOIN_WINDOW, {}) {
		j.close = true // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)

	ns := j.ns
	if ns == nil || ns != ui.session {
		join_form(ui, nil)
		return
	}
	v := ui.view
	sync.guard(&v.mutex)
	switch {
	case v.status == .Failed || v.status == .Disconnected:
		join_form(ui, v)
	case v.status == .Connecting:
		mu.layout_row(ctx, {-1})
		mu.label(ctx, fmt.tprintf("Connecting to %s...", v.server))
		mu.layout_row(ctx, {100})
		if .SUBMIT in mu.button(ctx, "Cancel") {
			j.close = true
		}
	case v.login.state != .Done:
		login_screen(ui)
	case:
		mu.layout_row(ctx, {-1})
		mu.label(ctx, "Logged in.")
	}
}

/*
join_form is the dialog's address and password, with what went wrong
the last time if anything did, and the trust prompt for a server whose
key has changed. `v` is the failed session's View, locked, or nil.
*/
@(private = "file")
join_form :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	j := &ui.join
	mu.layout_row(ctx, {80, -1})
	mu.label(ctx, "Server")
	submit := .SUBMIT in text_box(ui, j.server_buf[:], &j.server_len)
	mu.label(ctx, "Password")
	submit |= .SUBMIT in password_box(ui, j.password_buf[:], &j.password_len)
	mu.layout_row(ctx, {80, 100, 100})
	mu.label(ctx, "")
	submit |= .SUBMIT in mu.button(ctx, "Connect")
	if .SUBMIT in mu.button(ctx, "Cancel") {
		j.close = true
	}
	if submit && strings.trim_space(string(j.server_buf[:j.server_len])) != "" {
		j.connect = true
	}

	mu.layout_row(ctx, {-1})
	if v != nil && v.error != "" {
		with_text_color(ctx, ERROR_COLOR, v.error, label_proc)
	} else {
		with_text_color(
			ctx,
			DIM_COLOR,
			fmt.tprintf("The port is %d unless it's given (host:port).", proto.DEFAULT_PORT),
			label_proc,
		)
		with_text_color(ctx, DIM_COLOR, "The password is the server's, if it has one.", label_proc)
	}
	if v != nil && v.key_change.changed {
		key_change_panel(ui)
	}
}
