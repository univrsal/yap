package client

import log "common:wlog"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:idle"
import glfw "client:wglfw"
import "common:proto"

// Activity (see src/common/proto/activity.odin): a dot at the bottom right of
// people's pictures (green for online, yellow for away, red for busy, grey for
// offline), choosing our own activity (in the status window, see
// ui_profiles.odin), and noticing that nobody has touched this window for a
// while, which makes us away unless we chose otherwise.
//
// We are idle when there has been no input for IDLE_AFTER, anywhere on the
// desktop where the system reports it (see client:idle), and always in yap's
// own window. Input in either is enough not to be idle. Idleness is only
// checked while we chose to be online, because for any other choice the server
// shows what we chose regardless of idleness. Otherwise we are not idle.

// No input for this long counts as idle: ten minutes, or the value of
// -define:YAP_IDLE_SECONDS=n for testing.
IDLE_SECONDS :: #config(YAP_IDLE_SECONDS, 600)
IDLE_AFTER :: IDLE_SECONDS * time.Second
// How often the system is asked. It isn't asked on every turn of the loop,
// because on X11 each query is a round trip to the X server.
@(private = "file")
IDLE_CHECK_EVERY :: min(15 * time.Second, IDLE_AFTER / 4)

UI_Activity :: struct {
	last_input:   time.Tick, // in the window
	source:       idle.Source, // where the system's idle comes from
	opened:       bool,
	last_check:   time.Tick,
	system_idle:  bool, // as the system last reported, if it could
	system_known: bool,
	idle:         bool, // as last determined (per session, see Net_Session.idle_told)
	hidden:       bool, // whether the page is out of sight (web only, see ui_push_web.odin)
}

ACTIVITY_COLORS := [proto.Activity]mu.Color {
	.Online  = {80, 190, 100, 255},
	.Away    = {230, 180, 70, 255},
	.Busy    = {220, 75, 70, 255},
	.Offline = {125, 125, 125, 255},
}

ACTIVITY_LABELS := [proto.Activity]string {
	.Online  = "Online",
	.Away    = "Away",
	.Busy    = "Busy",
	.Offline = "Invisible",
}

ACTIVITY_HINTS := [proto.Activity]string {
	.Online  = "Online, and away by itself after 10 minutes without input",
	.Away    = "Away",
	.Busy    = "Busy: no sounds but for mentions and calls",
	.Offline = "Appear offline to everyone else",
}

// activity_input notices input in the window since the last frame, before
// microui takes it. Call once per frame, before mu.begin.
activity_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	input :=
		ctx.mouse_pos != ctx.last_mouse_pos ||
		ctx.mouse_pressed_bits != {} ||
		ctx.key_pressed_bits != {} ||
		ctx.scroll_delta != {} ||
		strings.builder_len(ctx.text_input) > 0
	if input {
		ui.activity.last_input = time.tick_now()
	}
}

// activity_step works out whether we are idle and tells the network side
// when that changes. Call it on every turn of the loop, drawn or not, hidden
// window or not. It draws nothing.
activity_step :: proc(ui: ^UI) {
	a := &ui.activity
	now := time.tick_now()
	if a.last_input == {} {
		a.last_input = now
	}
	if !a.opened {
		a.opened = true
		wayland, x11: rawptr
		switch glfw.GetPlatform() {
		case glfw.PLATFORM_WAYLAND:
			wayland = glfw.GetWaylandDisplay()
		case glfw.PLATFORM_X11:
			x11 = glfw.GetX11Display()
		}
		a.source = idle.open(IDLE_AFTER, wayland, x11)
		log.infof("idle from: %v", a.source)
	}
	// Only asked while we chose to be online somewhere, because otherwise
	// it changes nothing.
	online := false
	for ns in ui.sessions {
		sync.guard(&ns.view.mutex)
		online ||= ns.view.my_activity == .Online
	}
	is_idle := false
	if online {
		if a.last_check == {} || time.tick_diff(a.last_check, now) >= IDLE_CHECK_EVERY {
			a.last_check = now
			a.system_idle, a.system_known = idle.check()
		}
		is_idle =
			time.tick_diff(a.last_input, now) >= IDLE_AFTER && (a.system_idle || !a.system_known)
	} else {
		// Asked again once we are online again.
		a.last_check = {}
	}
	// Whether the page is out of sight is reported regardless of the chosen
	// activity: it doesn't make anyone away, but it makes the server send us
	// push notifications (see ui_push_web.odin).
	hidden := page_hidden()
	// Every server is told once. A new connection starts out as not idle, and
	// the client tells it again after it has started over itself.
	a.idle, a.hidden = is_idle, hidden
	for ns in ui.sessions {
		if ns.idle_told != is_idle || ns.hidden_told != hidden {
			ns.idle_told, ns.hidden_told = is_idle, hidden
			conn.push_command(
				&ns.client.commands,
				conn.Idle_Command{idle = is_idle, hidden = hidden},
			)
		}
	}
}

activity_close :: proc(ui: ^UI) {
	if ui.activity.opened {
		idle.close()
		ui.activity.opened = false
	}
}

// activity_dot draws an account's dot over the bottom right corner of its
// picture, which is drawn in `r`, with a dark edge so it is visible on any
// picture. Call with the View locked.
activity_dot :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	acc, known := ui.view.accounts[account]
	if !known {
		return
	}
	d := max(r.w / 3, 7)
	edge := mu.Rect{r.x + r.w - d + 1, r.y + r.h - d + 1, d + 1, d + 1}
	disc(ui, edge, theme.dot_ring)
	disc(ui, edge, ACTIVITY_COLORS[acc.activity], inset = 1)
}

// activity_dot_alone draws just the dot, centered in `r`, for places where
// there is no picture (the compact chat).
activity_dot_alone :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	acc, known := ui.view.accounts[account]
	if !known {
		return
	}
	d: i32 = 8
	disc(ui, {r.x + (r.w - d) / 2, r.y + (r.h - d) / 2, d, d}, ACTIVITY_COLORS[acc.activity])
}
