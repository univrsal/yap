package client

import "core:fmt"
import "core:time"
import mu "vendor:microui"

import "common:proto"
import "client:conn"
import "client:render"

/*
The voice panel, at the foot of the channel list and the buddy list (in
a narrow window, across the foot of the screen):

	Voice connected            (or: In a call, Calling..., Incoming call)
	# Lobby  12:34             (or whom the call is with)
	[music] [share]  [ Leave ] (Hang up; Accept Decline; Cancel)
	---------------------------------------------------
	(pic) alice  in a meeting               [mic] [speaker]

The top part only while our voice is somewhere (a channel's room, or a
call on this device) or a call rings; the bottom always: who we are,
with our status (clicking it sets it), and mute and deafen.
*/

UI_Voice_Panel :: struct {
	// Where our voice was last frame, and since when: for how long.
	room:  proto.Room,
	since: time.Tick,
}

@(private = "file")
PANEL_COLOR :: mu.Color{38, 38, 38, 255}
@(private = "file")
CONNECTED_COLOR :: mu.Color{110, 200, 120, 255}
@(private = "file")
RINGING_COLOR :: mu.Color{230, 180, 90, 255}

@(private = "file")
Panel_State :: enum {
	Idle, // nowhere: only the bottom part
	Voice, // in a channel's room
	Call, // in a call, on this device
	Ringing_In,
	Ringing_Out, // ours, from this device
	Elsewhere, // a call on another of our devices
}

@(private = "file")
panel_state :: proc(v: ^conn.View) -> Panel_State {
	switch v.call.status {
	case .None:
	case .Ringing_In:
		return .Ringing_In
	case .Ringing_Out:
		return .Ringing_Out if v.call.here else .Elsewhere
	case .Active:
		return .Call if v.call.here else .Elsewhere
	}
	if v.my_room != 0 && proto.room_call(proto.Room(v.my_room)) == 0 {
		return .Voice
	}
	return .Idle
}

/*
call_peer_row is the line of a call about whom it's with: their
picture, ringed while they're heard; their name; the mic or speaker
crossed out if they're muted or deafened; and how long it has lasted.
*/
@(private = "file")
call_peer_row :: proc(ui: ^UI, p: ^UI_Voice_Panel) {
	ctx := &ui.ctx
	v := &ui.view
	// Their device in the call's room: the one whose state counts.
	room := proto.call_room(v.call.id)
	peer: conn.View_User
	num: proto.User_Num
	for n, u in v.users {
		if u.account == v.call.peer && u.room == room {
			peer, num = u, n
			break
		}
	}
	slot := picture_slot(ctx)
	icon, icon_color := their_status(peer, num != 0 && conn.is_speaking(v, num))
	mu.layout_row(ctx, {slot + PICTURE_GAP, -(60 + render.ICON_SIZE + 2 * ctx.style.spacing), render.ICON_SIZE + 4, 56}, max(slot, ctx.style.size.y + 2 * ctx.style.padding))
	cell := mu.layout_next(ctx)
	talking := num != 0 && conn.is_speaking(v, num) && !peer.muted
	avatar_ringed(ui, v.call.peer, {cell.x, cell.y + (cell.h - slot) / 2, slot, slot}, talking)
	mu.label(ctx, call_peer_name(v))
	// Only what's worth saying: muted or deafened, not "can be heard".
	if num != 0 && (peer.muted || peer.deafened) {
		status_icon(ctx, icon, icon_color)
		if ctx.hover_root == mu.get_current_container(ctx) && mu.mouse_over(ctx, ctx.last_rect) {
			ui.hint, ui.hint_of = "Deafened: hears nobody" if peer.deafened else "Muted", ctx.last_rect
		}
	} else {
		mu.label(ctx, "")
	}
	length := call_length_shown(ui, p.since)
	with_text_color(ctx, DIM_COLOR, length, label_proc)
}

/*
A picture in the panel, with the room its ring takes round it
(avatar_ringed): the picture a little taller than a line of text, so
its initial fits, and the slot that much more. The rows with a picture
are as tall as the slot, which is taller than other rows (picture_extra),
so the ring stays clear of the rows above and below; and a gap after it
before the name.
*/
@(private = "file")
picture_slot :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.text_height(ctx.style.font) + 6 + 2 * RING_SPACE
}
@(private = "file")
picture_extra :: proc(ctx: ^mu.Context) -> i32 {
	return max(picture_slot(ctx) - (ctx.style.size.y + 2 * ctx.style.padding), 0)
}
@(private = "file")
PICTURE_GAP :: 6

@(private = "file")
row_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
}

// voice_panel_height is how tall the panel is this frame. Call with the
// View locked.
voice_panel_height :: proc(ui: ^UI) -> i32 {
	ctx := &ui.ctx
	rows: i32 = 1
	// Ours, and in a call the other side's, have a picture.
	pictures: i32 = 1
	switch panel_state(&ui.view) {
	case .Idle:
	case .Elsewhere:
		rows += 2
	case .Call:
		rows += 3
		pictures += 1
	case .Voice, .Ringing_In, .Ringing_Out:
		rows += 3
	}
	return rows * row_height(ctx) + pictures * picture_extra(ctx) + 2 * ctx.style.padding
}

/*
voice_panel draws the panel in the current layout cell (a column's next
row, as tall as voice_panel_height). Call with the View locked.
*/
voice_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	p := &ui.voice_panel
	call_announce(ui)
	state := panel_state(v)

	// How long we've been where we are.
	room := proto.Room(v.my_room) if state == .Voice else (proto.call_room(v.call.id) if state == .Call else 0)
	if room != p.room {
		p.room, p.since = room, time.tick_now()
	}
	if state == .Call {
		p.since = v.call.since
	}

	mu.layout_row(ctx, {-1}, voice_panel_height(ui) - ctx.style.spacing)
	r := mu.layout_next(ctx)
	mu.draw_rect(ctx, r, PANEL_COLOR)
	pad := ctx.style.padding
	mu.layout_set_next(ctx, {r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad}, false)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	cmds := &ui.session.client.commands if ui.session != nil else nil
	command :: proc(cmds: ^conn.Command_Queue, cmd: conn.Command) {
		if cmds != nil {
			conn.push_command(cmds, cmd)
		}
	}

	if state != .Idle {
		what, color: = "", CONNECTED_COLOR
		where_ := ""
		switch state {
		case .Idle:
		case .Voice:
			what = "Voice connected"
			where_ = fmt.tprintf("# %s", voice_room_name(v))
		case .Call:
			what = "In a call"
			where_ = call_peer_name(v)
		case .Ringing_In:
			what, color = "Incoming call", RINGING_COLOR
			where_ = call_peer_name(v)
		case .Ringing_Out:
			what, color = "Calling...", RINGING_COLOR
			where_ = call_peer_name(v)
		case .Elsewhere:
			what, color = "In a call on another device", DIM_COLOR
			where_ = call_peer_name(v)
		}
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, color, what, label_proc)
		if state == .Call {
			call_peer_row(ui, p)
		} else if state == .Voice {
			mu.layout_row(ctx, {-60, 56})
			mu.label(ctx, where_)
			length := call_length_shown(ui, p.since)
			with_text_color(ctx, DIM_COLOR, length, label_proc)
		} else {
			mu.layout_row(ctx, {-1})
			mu.label(ctx, where_)
		}

		switch state {
		case .Idle, .Elsewhere:
		case .Ringing_In:
			mu.layout_row(ctx, {-(90 + ctx.style.spacing), 90})
			if .SUBMIT in stable_button(ctx, "call accept", "Accept", {.ALIGN_CENTER}) {
				command(cmds, conn.Call_Answer_Command{})
			}
			if .SUBMIT in stable_button(ctx, "call decline", "Decline", {.ALIGN_CENTER}) {
				command(cmds, conn.Call_Hangup_Command{})
			}
		case .Ringing_Out:
			mu.layout_row(ctx, {-1})
			if .SUBMIT in stable_button(ctx, "call cancel", "Cancel", {.ALIGN_CENTER}) {
				command(cmds, conn.Call_Hangup_Command{})
			}
		case .Voice, .Call:
			// What may be shared there, then the way out.
			widths := make([dynamic]i32, context.temp_allocator)
			can_share := conn.video_can_share()
			can_music := app_audio_available(ui)
			if can_music {
				append(&widths, ICON_BUTTON)
			}
			if can_share {
				append(&widths, ICON_BUTTON)
			}
			append(&widths, -1)
			mu.layout_row(ctx, widths[:])
			if can_music {
				app_audio_button(ui)
			}
			if can_share {
				share_button(ui)
			}
			label := "Hang up" if state == .Call else "Leave"
			saved := ctx.style.colors[.TEXT]
			ctx.style.colors[.TEXT] = OFF_COLOR
			leave := .SUBMIT in stable_button(ctx, "voice leave", label, {.ALIGN_CENTER})
			ctx.style.colors[.TEXT] = saved
			if leave {
				if state == .Call {
					command(cmds, conn.Call_Hangup_Command{})
				} else {
					command(cmds, conn.Voice_Command{})
				}
			}
		}
	}

	// Who we are, and mute and deafen.
	slot := picture_slot(ctx)
	mu.layout_row(ctx, {slot + PICTURE_GAP, -(2 * ICON_BUTTON + 2 * ctx.style.spacing), ICON_BUTTON, ICON_BUTTON}, max(slot, ctx.style.size.y + 2 * ctx.style.padding))
	cell := mu.layout_next(ctx)
	talking := (state == .Voice || state == .Call) && conn.is_speaking(v, v.my_num)
	avatar_ringed(ui, v.me, {cell.x, cell.y + (cell.h - slot) / 2, slot, slot}, talking)
	id := mu.get_id(ctx, "me in panel")
	me_r := mu.layout_next(ctx)
	mu.update_control(ctx, id, me_r)
	if ctx.hover_id == id {
		mu.draw_rect(ctx, me_r, ctx.style.colors[.BUTTON_HOVER])
		ui.hint, ui.hint_of = "Set your status", me_r
		if .LEFT in ctx.mouse_pressed_bits {
			open_status_editor(ui)
		}
	}
	me := v.accounts[v.me] or_else {}
	name := me.display if me.display != "" else v.my_name
	name_and_status(ctx, me_r, name, ctx.style.colors[.TEXT], status_line(me))
	if .SUBMIT in
	   icon_button(ui, "mute", .Mic_Off if ui.muted else .Mic, "Unmute" if ui.muted else "Mute", OFF_COLOR if ui.muted else mu.Color{}) {
		set_muted(ui, !ui.muted)
	}
	if .SUBMIT in
	   icon_button(
		   ui,
		   "deafen",
		   .Sound_Off if ui.deafened else .Sound,
		   "Undeafen" if ui.deafened else "Deafen (hear nobody)",
		   OFF_COLOR if ui.deafened else mu.Color{},
	   ) {
		set_deafened(ui, !ui.deafened)
	}
}

// call_length_shown is how long it's been since `since`, as a call's
// length, with a frame asked for when the next second ticks over.
@(private = "file")
call_length_shown :: proc(ui: ^UI, since: time.Tick) -> string {
	d := time.tick_since(since)
	ui_redraw_in(ui, time.Second - d % time.Second)
	return conn.call_length(int(d / time.Second))
}
