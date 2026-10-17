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

// Our activity and our status are the same on every server we are connected
// to, except the ones where we chose not to share them (status_shared).
// Choosing one sets it on all of them (activity_set_all, status_set_all).
// A server that missed it (it was unreachable, or we were not connected) or
// that has a newer one (chosen on another device, connected only to that
// server) is noticed by status_sync, which copies the newest of each to the
// servers that have something else. Each server says when its own were chosen
// (proto.self_times), a copy keeps that time, and a server only takes a copy
// that is newer than what it has, so the servers can't take turns undoing each
// other.

// Status_Copied is what status_sync last copied to a server: the times of the
// activity and of the status, and when they were copied.
Status_Copied :: struct {
	activity_at:   proto.Unix_Ms,
	activity_tick: time.Tick,
	status_at:     proto.Unix_Ms,
	status_tick:   time.Tick,
}

// A copy that the server still doesn't show after this long is sent again.
@(private = "file")
COPY_RETRY :: 5 * time.Second

// status_shared is whether our activity, status and talking are shared
// between this server and our other servers (conn.SETTING_STATUS_SHARED).
// Until the account's settings have arrived, they aren't, so that nothing is
// shared with a server where we chose not to. Call with the View locked.
status_shared :: proc(v: ^conn.View) -> bool {
	return(
		v.shared_synced &&
		(v.shared[conn.SETTING_STATUS_SHARED] or_else "") != conn.STATUS_SHARED_OFF \
	)
}

// status_target is whether choosing an activity or a status in the window
// applies to the session's server: the shown one, and if that one shares
// them, every other one that does too. It goes by Net_Session.status_ready
// and .status_shared (from status_sync) and takes no View's lock, because the
// status window has the shown one locked.
@(private = "file")
status_target :: proc(ui: ^UI, ns: ^Net_Session) -> bool {
	if !ns.status_ready {
		return false
	}
	if ns == ui.session {
		return true
	}
	return ui.session != nil && ui.session.status_shared && ns.status_shared
}

// activity_set_all chooses our activity on every server it applies to
// (status_target).
activity_set_all :: proc(ui: ^UI, a: proto.Activity) {
	for ns in ui.sessions {
		if status_target(ui, ns) {
			conn.push_command(&ns.client.commands, conn.Activity_Command{activity = a})
		}
	}
}

// status_set_all sets our status on every server it applies to
// (status_target): "" for none, clearing itself at `until` (0 for never).
status_set_all :: proc(ui: ^UI, text: string, until: proto.Unix_Ms) {
	for ns in ui.sessions {
		if status_target(ui, ns) {
			conn.push_command(
				&ns.client.commands,
				conn.Status_Command{text = strings.clone(text), until = until},
			)
		}
	}
}

// status_sync notes which servers can be told our activity and status and
// which share them (Net_Session.status_ready and .status_shared), and copies
// the newest activity and the newest status among those that share them to
// the ones that have something else (see above). It is called before the
// frame is drawn, with no View locked.
status_sync :: proc(ui: ^UI) {
	Mine :: struct {
		known:        bool,
		activity:     proto.Activity,
		activity_at:  proto.Unix_Ms,
		status:       string, // in the temp allocator
		status_until: proto.Unix_Ms,
		status_at:    proto.Unix_Ms,
	}
	mine := make([]Mine, len(ui.sessions), context.temp_allocator)
	newest_activity, newest_status := -1, -1
	for ns, i in ui.sessions {
		ns.status_ready, ns.status_shared = false, false
		if ns.joining {
			continue
		}
		v := &ns.view
		sync.guard(&v.mutex)
		if v.status != .Connected || v.login.state != .Done {
			continue
		}
		ns.status_ready = true
		ns.status_shared = status_shared(v)
		if !ns.status_shared {
			continue
		}
		me, ok := v.accounts[v.me]
		if !ok {
			continue
		}
		m := &mine[i]
		m^ = {
			known        = true,
			activity     = v.my_activity,
			activity_at  = v.my_activity_at,
			status       = strings.clone(me.status, context.temp_allocator),
			status_until = me.status_until,
			status_at    = v.my_status_at,
		}
		// Only a server that says when can have the newest.
		if m.activity_at != 0 &&
		   (newest_activity < 0 || m.activity_at > mine[newest_activity].activity_at) {
			newest_activity = i
		}
		if m.status_at != 0 &&
		   (newest_status < 0 || m.status_at > mine[newest_status].status_at) {
			newest_status = i
		}
	}

	now := time.tick_now()
	for ns, i in ui.sessions {
		m := mine[i]
		if !m.known {
			continue
		}
		copied := &ns.status_copied
		if newest_activity >= 0 {
			n := mine[newest_activity]
			if m.activity != n.activity &&
			   n.activity_at > m.activity_at &&
			   (copied.activity_at != n.activity_at ||
					   time.tick_diff(copied.activity_tick, now) >= COPY_RETRY) {
				copied.activity_at, copied.activity_tick = n.activity_at, now
				log.infof("ui: copying the activity %v to %s", n.activity, ns.server)
				conn.push_command(
					&ns.client.commands,
					conn.Activity_Command{activity = n.activity, at = n.activity_at},
				)
			}
		}
		if newest_status >= 0 {
			n := mine[newest_status]
			if (m.status != n.status || m.status_until != n.status_until) &&
			   n.status_at > m.status_at &&
			   (copied.status_at != n.status_at ||
					   time.tick_diff(copied.status_tick, now) >= COPY_RETRY) {
				copied.status_at, copied.status_tick = n.status_at, now
				log.infof("ui: copying the status to %s", ns.server)
				conn.push_command(
					&ns.client.commands,
					conn.Status_Command {
						text = strings.clone(n.status),
						until = n.status_until,
						at = n.status_at,
					},
				)
			}
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
