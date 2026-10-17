package client

import "client:conn"
import "client:platform"
import "client:settings"
import "common:proto"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

// Joining a server from the rail's + button (docs/next, item 9b), which is also
// picked automatically when there is no server to show: the main window asks
// for the server's address and password, and connects. From then on the new
// session is in UI.sessions (its network turns, mute, idle etc. are handled
// like those of every other session) and is shown, but it is marked `joining`:
// it is left off the rail and out of the settings, and the main window shows
// the join page.
//
// What happens next depends on the server, and the page shows it in place. A
// server that knows this device logs it in automatically, and the server is
// joined: it appears on the rail and in the settings, and the page goes away.
// A server that doesn't know the device brings up the login screen (with
// Register where the server allows it). A server whose key has changed brings
// up the trust prompt, and a failed connection shows the form again with what
// went wrong.
//
// Giving up (Cancel while connecting, a click elsewhere on the rail, or opening
// the settings) ends the session and shows whatever was shown before.

UI_Join :: struct {
	open:         bool, // the + button is selected
	card_h:       i32, // the card's height in the last frame (card_end)
	server_buf:   [256]u8,
	server_len:   int,
	password_buf: [proto.MAX_PASSWORD_SIZE]u8,
	password_len: int,
	// The session being joined, which is shown until it is logged in, and
	// the session shown before, to go back to.
	ns:           ^Net_Session,
	back:         ^Net_Session,
	// Requested on the page, but done after the frame (join_frame), because
	// connecting waits on the network thread, which may be waiting on the
	// View lock.
	connect:      bool,
	close:        bool,
	// Why the typed address wasn't tried, shown in the card (a constant).
	mistake:      string,
}

// join_open opens the + page with an empty form.
join_open :: proc(ui: ^UI) {
	if ui.join.open {
		return
	}
	ui.join = {
		open = true,
	}
}

// join_frame does what the page requested in the last frame, and once the
// session being joined is logged in, puts it on the rail and in the settings.
// Call between frames, with no View locked.
join_frame :: proc(ui: ^UI) {
	j := &ui.join
	if j.close {
		join_close(ui)
	}
	// With no server to show, the only thing left is to join one: either we
	// started without any server, or the last one was left or given up.
	if ui.session == nil && ui.page != .Settings && !j.open {
		join_open(ui)
		ui_redraw(ui)
	}
	if j.connect {
		j.connect = false
		typed := string(j.server_buf[:j.server_len])
		// A browser reaches a server through the relay beside its web page, so
		// that page's address is what the web client joins (see relay_blocked).
		j.mistake = ""
		when platform.WEB {
			if !conn.is_web_address(typed) {
				j.mistake = "Enter the server's web address, like https://chat.example.org or http://localhost:8080."
				typed = ""
			}
		}
		if typed != "" {
			join_connect(ui, typed, string(j.password_buf[:j.password_len]))
		}
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

// join_connect connects the page to `server`. It creates and shows a new
// session, which replaces the page's previous session if there is one (because
// it failed, or its key was just trusted). If the server has already been
// joined, that session is shown instead and the page is closed.
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
	when platform.WEB {
		relay_claim(ui, server)
	}
	if !relay_blocked(ui, ns) {
		net_start(ns)
	}
}

// join_close closes the page, giving up the session it was joining, if any, and
// shows the session that was shown before. Call between frames.
join_close :: proc(ui: ^UI) {
	j := ui.join
	ui.join = {}
	ns := j.ns
	if ns == nil {
		return
	}
	log.infof("ui: gave up joining %s", ns.server)
	relay_release(ui, ns.server)
	session_remove(ui, ns)
	for other in ui.sessions {
		if other == j.back {
			show_session(ui, other)
		}
	}
	session_free(ui, ns)
}

// join_page draws the main window while a server is being joined, from the +
// button or because there is no server to show. It shows the address and
// password form, then the connection progress, then the server's login, or the
// form again with what went wrong.
join_page :: proc(ui: ^UI) {
	ctx := &ui.ctx
	j := &ui.join
	ns := j.ns
	if ns == nil || ns != ui.session {
		join_card(ui, nil)
		return
	}
	v := ui.view
	sync.guard(&v.mutex)
	switch {
	case v.status == .Failed || v.status == .Disconnected:
		join_card(ui, v)
	case v.status == .Connecting:
		card_begin(ui, "join card", j.card_h)
		defer card_end(ui, &j.card_h)
		card_heading(ui, fmt.tprintf("Connecting to %s...", v.server))
		mu.layout_row(ctx, {-1})
		if .SUBMIT in mu.button(ctx, "Cancel") {
			j.close = true
		}
	case v.login.state != .Done:
		login_screen(ui)
	case:
		card_begin(ui, "join card", j.card_h)
		defer card_end(ui, &j.card_h)
		card_heading(ui, "Logged in.")
	}
}

// join_card draws the page's address and password form in a card like the
// login screen's, with the error from the last attempt if there was one, and
// the trust prompt for a server whose key has changed. `v` is the failed
// session's View (locked), or nil.
@(private = "file")
join_card :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	j := &ui.join
	card_begin(ui, "join card", j.card_h)
	defer card_end(ui, &j.card_h)
	card_heading(ui, "Join a server")
	mu.layout_row(ctx, {-1}, ctx.style.spacing)
	mu.layout_next(ctx)

	mu.layout_row(ctx, {LOGIN_LABEL, -1})
	mu.label(ctx, "Server")
	submit := .SUBMIT in text_box(ui, j.server_buf[:], &j.server_len)
	mu.label(ctx, "Password")
	submit |= .SUBMIT in password_box(ui, j.password_buf[:], &j.password_len)
	mu.label(ctx, "")
	submit |= .SUBMIT in mu.button(ctx, "Connect")
	if submit && strings.trim_space(string(j.server_buf[:j.server_len])) != "" {
		j.connect = true
	}

	mu.layout_row(ctx, {-1})
	if j.mistake != "" {
		with_text_color(ctx, theme.error, j.mistake, wrap_text)
	} else if v != nil && v.error != "" {
		with_text_color(ctx, theme.error, v.error, wrap_text)
	}
	if v != nil && v.key_change.changed {
		key_change_panel(ui)
	}
}
