package client

import "core:strings"
import "core:time"
import mu "vendor:microui"

import "common:proto"
import "client:conn"

/*
Activity (src/common/proto/activity.odin): a dot at the bottom right of
people's pictures, green online, yellow away, red busy, grey offline;
choosing ours (the status window, ui_profiles.odin); and noticing that
nobody has touched this window for a while, which makes us away unless
we chose otherwise.

Idle is input in yap's own window only: there's no asking the desktop
about input elsewhere yet.
*/

// No input in the window for this long is idle: ten minutes, or for
// testing, -define:YAP_IDLE_SECONDS=n.
IDLE_SECONDS :: #config(YAP_IDLE_SECONDS, 600)
IDLE_AFTER :: IDLE_SECONDS * time.Second

UI_Activity :: struct {
	last_input: time.Tick,
	idle:       bool, // as last told the network side
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

/*
activity_input notices input since the last frame, before microui takes
it: any is activity, and none for IDLE_AFTER is idle, which the network
side tells the server either way. Call once a frame, before mu.begin.
*/
activity_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	a := &ui.activity
	if a.last_input == {} {
		a.last_input = time.tick_now()
	}
	input :=
		ctx.mouse_pos != ctx.last_mouse_pos ||
		ctx.mouse_pressed_bits != {} ||
		ctx.key_pressed_bits != {} ||
		ctx.scroll_delta != {} ||
		strings.builder_len(ctx.text_input) > 0
	idle := a.idle
	if input {
		a.last_input = time.tick_now()
		idle = false
	} else if time.tick_since(a.last_input) >= IDLE_AFTER {
		idle = true
	}
	if idle != a.idle && ui.session != nil {
		a.idle = idle
		conn.push_command(&ui.session.client.commands, conn.Idle_Command{idle = idle})
	}
	if !idle {
		ui_redraw_at(ui, time.tick_add(a.last_input, IDLE_AFTER))
	}
}

/*
activity_dot draws an account's dot over the bottom right corner of its
picture, drawn in `r`, with a dark edge so it reads on any picture. Call
with the View locked.
*/
activity_dot :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	acc, known := ui.view.accounts[account]
	if !known {
		return
	}
	d := max(r.w / 3, 7)
	edge := mu.Rect{r.x + r.w - d + 1, r.y + r.h - d + 1, d + 1, d + 1}
	disc(ui, edge, {32, 32, 32, 255})
	disc(ui, {edge.x + 1, edge.y + 1, d - 1, d - 1}, ACTIVITY_COLORS[acc.activity])
}

// activity_dot_alone draws just the dot, centred in `r`: for where
// there's no picture (the compact chat).
activity_dot_alone :: proc(ui: ^UI, account: proto.Account_Id, r: mu.Rect) {
	acc, known := ui.view.accounts[account]
	if !known {
		return
	}
	d: i32 = 8
	disc(ui, {r.x + (r.w - d) / 2, r.y + (r.h - d) / 2, d, d}, ACTIVITY_COLORS[acc.activity])
}
