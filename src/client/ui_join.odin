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
Joining a server from the rail's + (docs/next, item 9b), picked by
itself with no server to show: the main window asks for its address and
password, and connects. The session it makes is among UI.sessions from
then on (its network turns, mute, idle... go to it as to every other),
and shown, but marked `joining`: off the rail, with the join page in the
main window, and not in the settings.

What happens next is the server's to say, and the page shows it in
place: a server that knows this device logs it in by itself, and it's
joined - on the rail, in the settings, the page gone. One that doesn't
asks for the login screen (with Register where the server allows it);
one whose key has changed, the trust prompt; a failed connection, the
form again with what went wrong.

Giving up (Cancel while connecting, a click elsewhere on the rail, the
settings) ends the session and shows again what was shown before.
*/

UI_Join :: struct {
	open:         bool, // the + is picked
	card_h:       i32, // the card's height last frame (card_end)
	server_buf:   [256]u8,
	server_len:   int,
	password_buf: [proto.MAX_PASSWORD_SIZE]u8,
	password_len: int,
	// The session being joined, the one shown till it's logged in; and
	// the one shown before, to go back to.
	ns:           ^Net_Session,
	back:         ^Net_Session,
	// Asked for on the page, done after the frame (join_frame):
	// connecting waits on the network thread, which may be waiting on
	// the View lock.
	connect:      bool,
	close:        bool,
}

// join_open opens the + page, empty.
join_open :: proc(ui: ^UI) {
	if ui.join.open {
		return
	}
	ui.join = {
		open = true,
	}
}

/*
join_frame does what the page asked for in the last frame, and once
the session it's joining is logged in, puts it on the rail and in the
settings. Between frames, with no View locked.
*/
join_frame :: proc(ui: ^UI) {
	j := &ui.join
	if j.close {
		join_close(ui)
	}
	// With no server to show, there's nothing but joining one: started
	// up on none yet, or the last one left or given up.
	if ui.session == nil && ui.page != .Settings && !j.open {
		join_open(ui)
		ui_redraw(ui)
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
join_connect connects the page to `server`: a new session, shown, or
one in place of the page's last (failed, or with its key just
trusted). A server joined already is shown instead, and the page
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

// join_close closes the page, giving up the session it was joining,
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

/*
join_page is the main window while a server is joined, from the + or
with none to show: the address and password, then the connection, then
the server's login; or the form again, with what went wrong.
*/
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

/*
join_card is the page's address and password in a card, as the login
screen's, with what went wrong the last time if anything did, and the
trust prompt for a server whose key has changed. `v` is the failed
session's View, locked, or nil.
*/
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
	if v != nil && v.error != "" {
		with_text_color(ctx, theme.error, v.error, mu.text)
	}
	if v != nil && v.key_change.changed {
		key_change_panel(ui)
	}
}
