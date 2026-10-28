package client

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:video"
import "common:proto"

// The voice panel is at the foot of the channel list and the buddy list (in a
// narrow window, across the foot of the screen):
//
//	Voice connected            (or: In a call, Calling..., Incoming call)
//	# Lobby  12:34             (or whom the call is with)
//	[music] [share]  [ (hang up) ] (leave or hang up; Accept Decline; cancel)
//	---------------------------------------------------
//	(pic) alice  in a meeting               [mic] [speaker]
//
// The top part is only shown while our voice is somewhere (a channel's room, or
// a call on this device) or a call is ringing. The bottom part is always shown:
// who we are, with our status (clicking it sets it), and mute and deafen. In a
// narrow window, which needs the height for the messages, our picture and
// mute and deafen are in the rail instead (rail_bottom), and the panel is
// left out unless the top part has something to show.
//
// Voice is in one server at a time, and it stays there when another server is
// shown. Then the panel has an extra part above the rest for it, which shows
// where it is with the server's name, a button that shows that server, and the
// way out. It does the same for a call that is ringing in another server:
//
//	Voice connected on Bravo
//	# Lobby  12:34
//	[ Show ]  [ (hang up) ]
//
// The way out (leaving, hanging up, cancelling a call) is always the red
// receiver put down, as for declining a call (hang_up_button).

// Voice_Elsewhere is our voice, or a call that is ringing, in a server that
// isn't shown, as of this frame. It is worked out before the layout
// (voice_elsewhere_update), with that server's View locked in turn, so that the
// panel's height and what it draws agree without needing that lock.
Voice_Elsewhere :: struct {
	ns:     ^Net_Session, // nil: nothing elsewhere
	state:  Panel_State,
	// These strings are in the temp allocator.
	server: string,
	where_: string,
	since:  time.Tick,
}

UI_Voice_Panel :: struct {
	// Where our voice was in the last frame, and since when, to work out for how long.
	room:  proto.Room,
	since: time.Tick,
}

Panel_State :: enum {
	Idle, // nowhere: only the bottom part is shown
	Voice, // in a channel's room
	Call, // in a call, on this device
	Ringing_In,
	Ringing_Out, // ours, from this device
	Elsewhere, // a call on another of our devices
}

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

// call_peer_row is the line of a call about whom it is with: their picture,
// ringed while they are heard, their name, the mic or speaker crossed out if
// they are muted or deafened, a button for watching their screen while they
// share it (they have no row in a channel's list to click), and how long the
// call has lasted.
@(private = "file")
call_peer_row :: proc(ui: ^UI, p: ^UI_Voice_Panel) {
	ctx := &ui.ctx
	v := ui.view
	num, peer := call_peer(v)
	slot := picture_slot(ctx)
	icon, icon_color := their_status(peer, num != 0 && conn.is_speaking(v, num))
	watching := num != 0 && v.watching == num
	can_watch := num != 0 && peer.sharing && (can_watch_screens(ui) || watching)
	widths := make([dynamic]i32, context.temp_allocator)
	append(&widths, slot + PICTURE_GAP)
	name_w := -(60 + render.ICON_SIZE + 2 * ctx.style.spacing)
	if can_watch {
		name_w -= icon_button_w(ctx) + ctx.style.spacing
	}
	append(&widths, name_w, render.ICON_SIZE + 4)
	if can_watch {
		append(&widths, icon_button_w(ctx))
	}
	append(&widths, 56)
	mu.layout_row(ctx, widths[:], max(slot, ctx.style.size.y + 2 * ctx.style.padding))
	cell := mu.layout_next(ctx)
	talking := num != 0 && conn.is_speaking(v, num) && !peer.muted
	avatar_ringed(ui, v.call.peer, {cell.x, cell.y + (cell.h - slot) / 2, slot, slot}, talking)
	mu.label(ctx, call_peer_name(v))
	// Only what is worth saying: muted or deafened, not "can be heard".
	if num != 0 && (peer.muted || peer.deafened) {
		status_icon(ctx, icon, icon_color)
		if ctx.hover_root == mu.get_current_container(ctx) && mu.mouse_over(ctx, ctx.last_rect) {
			ui.hint, ui.hint_of =
				"Deafened: hears nobody" if peer.deafened else "Muted", ctx.last_rect
		}
	} else {
		mu.label(ctx, "")
	}
	if can_watch {
		if .SUBMIT in
		   icon_button(
			   ui,
			   "watch peer",
			   .Screen_Off if watching else .Screen,
			   "Stop watching" if watching else "Watch their screen",
			   theme.speaking if watching else mu.Color{},
		   ) {
			watch(ui, 0 if watching else num)
		}
	}
	length := call_length_shown(ui, p.since)
	dim_label(ctx, length)
}

// A picture in the panel, with the room that its ring takes around it
// (avatar_ringed): the picture is a little taller than a line of text so that
// its initial fits, and the slot is that much larger. The rows with a picture
// are as tall as the slot, which is taller than other rows (picture_extra), so
// the ring stays clear of the rows above and below, and there is a gap after it
// before the name.
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

// voice_elsewhere_update records whether our voice, or a call that is ringing,
// is in a server other than the one shown (UI.voice_other). Call before the
// layout, with no View locked.
voice_elsewhere_update :: proc(ui: ^UI) {
	ui.voice_other = {}
	for ns in ui.sessions {
		if ns == ui.session || ns.joining {
			continue
		}
		v := &ns.view
		sync.guard(&v.mutex)
		state := panel_state(v)
		if state == .Idle || state == .Elsewhere {
			continue
		}
		e := Voice_Elsewhere {
			ns     = ns,
			state  = state,
			server = strings.clone(
				v.server_name if v.server_name != "" else ns.server,
				context.temp_allocator,
			),
		}
		switch state {
		case .Idle, .Elsewhere:
		case .Voice:
			e.where_ = fmt.tprintf("# %s", voice_room_name(v))
			// How long, as the panel there counts it (its stash's, which the
			// UI thread keeps).
			p := &ns.stash.voice_panel
			if room := proto.Room(v.my_room); p.room != room {
				p.room, p.since = room, time.tick_now()
			}
			e.since = p.since
		case .Call:
			e.where_ = strings.clone(call_peer_name(v), context.temp_allocator)
			e.since = v.call.since
		case .Ringing_In, .Ringing_Out:
			e.where_ = strings.clone(call_peer_name(v), context.temp_allocator)
		}
		ui.voice_other = e
		return
	}
}

// voice_panel_height is how tall the panel is in this frame. Call with the
// View locked.
voice_panel_height :: proc(ui: ^UI) -> i32 {
	ctx := &ui.ctx
	rows: i32 = 1
	if ui.voice_other.ns != nil {
		rows += 3
	}
	// Ours, and in a call the other side's, have a picture. Ours is in the
	// rail in a narrow window, and then without anything else there is no panel.
	pictures: i32 = 1
	if ui.narrow {
		rows, pictures = rows - 1, 0
	}
	switch panel_state(ui.view) {
	case .Idle:
	case .Elsewhere:
		rows += 2
	case .Call:
		rows += 3
		pictures += 1
	case .Voice, .Ringing_In, .Ringing_Out:
		rows += 3
	}
	if rows == 0 {
		return 0
	}
	return rows * row_height(ctx) + pictures * picture_extra(ctx) + 2 * ctx.style.padding
}

// voice_panel draws the panel in the current layout cell (a column's next row,
// as tall as voice_panel_height), if it has any height. Call with the View
// locked.
voice_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	p := &ui.voice_panel
	state := panel_state(v)
	height := voice_panel_height(ui)
	if height == 0 {
		return
	}

	// How long we have been where we are.
	room :=
		proto.Room(v.my_room) if state == .Voice else (proto.call_room(v.call.id) if state == .Call else 0)
	if room != p.room {
		p.room, p.since = room, time.tick_now()
	}
	if state == .Call {
		p.since = v.call.since
	}

	mu.layout_row(ctx, {-1}, height - ctx.style.spacing)
	r := mu.layout_next(ctx)
	mu.draw_rect(ctx, r, theme.panel)
	pad := ctx.style.padding
	mu.layout_set_next(ctx, {r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad}, false)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	if ui.voice_other.ns != nil {
		voice_elsewhere_part(ui, ui.voice_other)
	}

	if state != .Idle {
		what, color := "", theme.connected
		where_ := ""
		switch state {
		case .Idle:
		case .Voice:
			what = "Voice connected"
			if server_muted(v, v.me) {
				// Nobody hears us here, whatever the mic button says.
				what, color = "Muted by a moderator", theme.warning
			} else if !v.may_speak {
				what, color = "Listening only", theme.warning
			}
			where_ = fmt.tprintf("# %s", voice_room_name(v))
		case .Call:
			what = "In a call"
			where_ = call_peer_name(v)
		case .Ringing_In:
			what, color = "Incoming call", theme.ringing
			where_ = call_peer_name(v)
		case .Ringing_Out:
			what, color = "Calling...", theme.ringing
			where_ = call_peer_name(v)
		case .Elsewhere:
			what, color = "In a call on another device", theme.dim
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
			dim_label(ctx, length)
		} else {
			mu.layout_row(ctx, {-1})
			mu.label(ctx, where_)
		}

		switch state {
		case .Idle, .Elsewhere:
		case .Ringing_In:
			accept, video, decline := answer_buttons(ui, "call", camera_available(v))
			if accept || video {
				leave_voice_elsewhere(ui)
				command(ui, conn.Call_Answer_Command{})
			}
			if video {
				camera_on_call(ui)
			}
			if decline {
				command(ui, conn.Call_Hangup_Command{})
			}
		case .Ringing_Out:
			mu.layout_row(ctx, {-1})
			if hang_up_button(ui, "call cancel", "Cancel") {
				command(ui, conn.Call_Hangup_Command{})
			}
		case .Voice, .Call:
			// What may be shared there, then the way out.
			widths := make([dynamic]i32, context.temp_allocator)
			// Once started, sharing can always be stopped. Starting it takes
			// the media link and the right to use video there.
			can_share :=
				video.can_share() && ((v.video_link && v.may_video) || video.share_state() != .Off)
			// Shared audio goes out with our voice.
			can_music := app_audio_available(ui) && (v.may_speak || app_audio_on(ui))
			// Likewise the camera.
			can_camera :=
				camera_available(v) &&
				((v.video_link && v.may_video) || video.camera_state() != .Off)
			if can_music {
				append(&widths, icon_button_w(ctx))
			}
			if can_share {
				append(&widths, icon_button_w(ctx))
			}
			if can_camera {
				append(&widths, icon_button_w(ctx))
			}
			append(&widths, -1)
			mu.layout_row(ctx, widths[:])
			if can_music {
				app_audio_button(ui)
			}
			if can_share {
				share_button(ui)
			}
			if can_camera {
				camera_button(ui)
			}
			if hang_up_button(ui, "voice leave", "Hang up" if state == .Call else "Leave") {
				if state == .Call {
					command(ui, conn.Call_Hangup_Command{})
				} else {
					command(ui, conn.Voice_Command{})
				}
			}
		}
	}

	// Who we are, and mute and deafen (in the rail, in a narrow window).
	if ui.narrow {
		return
	}
	slot := picture_slot(ctx)
	mu.layout_row(
		ctx,
		{
			slot + PICTURE_GAP,
			-(2 * icon_button_w(ctx) + 2 * ctx.style.spacing),
			icon_button_w(ctx),
			icon_button_w(ctx),
		},
		max(slot, ctx.style.size.y + 2 * ctx.style.padding),
	)
	cell := mu.layout_next(ctx)
	talking := (state == .Voice || state == .Call) && conn.is_speaking(v, v.my_num)
	avatar_ringed(ui, v.me, {cell.x, cell.y + (cell.h - slot) / 2, slot, slot}, talking)
	id := mu.get_id(ctx, "me in panel")
	me_r := mu.layout_next(ctx)
	mu.update_control(ctx, id, me_r)
	if nav_control(ctx, id, me_r) {
		open_status_editor(ui)
	}
	if nav_focused(ctx, id) {
		ui.hint, ui.hint_of = "Set your status", me_r
	}
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
	mute_button(ui)
	deafen_button(ui)
}

// mute_button is the button that mutes and unmutes us, in the layout's next
// cell. Call with the View locked.
mute_button :: proc(ui: ^UI) {
	v := ui.view
	// A moderator's mute here is shown over our own, which the button still
	// switches (it is every server's).
	mic_icon, mic_hint, mic_color :=
		render.Icon.Mic_Off if ui.muted else render.Icon.Mic,
		"Unmute" if ui.muted else "Mute",
		theme.off if ui.muted else mu.Color{}
	if server_muted(v, v.me) {
		mic_icon, mic_color = .Mic_Off, theme.warning
		mic_hint =
			"Muted by a moderator here (click to unmute yourself elsewhere)" if ui.muted else "Muted by a moderator here (click to mute yourself elsewhere too)"
	} else if panel_state(v) == .Voice && !v.may_speak {
		mic_icon, mic_color = .Mic_Off, theme.warning
		mic_hint =
			"You may only listen in this room (click to unmute yourself elsewhere)" if ui.muted else "You may only listen in this room (click to mute yourself elsewhere too)"
	}
	if .SUBMIT in icon_button(ui, "mute", mic_icon, mic_hint, mic_color) {
		set_muted(ui, !ui.muted)
	}
}

// deafen_button is the button that deafens and undeafens us, in the layout's
// next cell.
deafen_button :: proc(ui: ^UI) {
	if .SUBMIT in
	   icon_button(
		   ui,
		   "deafen",
		   .Sound_Off if ui.deafened else .Sound,
		   "Undeafen" if ui.deafened else "Deafen (hear nobody)",
		   theme.off if ui.deafened else mu.Color{},
	   ) {
		set_deafened(ui, !ui.deafened)
	}
}

// answer_buttons are the Accept and Decline buttons for a call that is ringing,
// in a row of their own, half each: a green receiver picked up and a red one
// put down. With `video`, a green camera between them answers with our camera
// on, and each takes a third. `id_name` tells this set from another.
@(private = "file")
answer_buttons :: proc(
	ui: ^UI,
	id_name: string,
	video := false,
) -> (
	accept, with_video, decline: bool,
) {
	ctx := &ui.ctx
	w := mu.get_layout(ctx).body.w
	if video {
		third := (w - 2 * ctx.style.spacing) / 3
		mu.layout_row(ctx, {third, third, -1})
	} else {
		mu.layout_row(ctx, {(w - ctx.style.spacing) / 2, -1})
	}
	mu.push_id(ctx, id_name)
	defer mu.pop_id(ctx)
	accept = .SUBMIT in icon_button(ui, "accept", .Phone, "Accept", theme.connected)
	if video {
		with_video =
			.SUBMIT in
			icon_button(ui, "accept video", .Camera, "Answer with video", theme.connected)
	}
	decline = hang_up_button(ui, "decline", "Decline")
	return
}

// hang_up_button is the way out of a call or a voice chat, or of a call that is
// ringing: a red receiver put down, with `hint` saying what it does.
@(private = "file")
hang_up_button :: proc(ui: ^UI, id_name, hint: string) -> bool {
	return .SUBMIT in icon_button(ui, id_name, .Hang_Up, hint, theme.off)
}

// voice_elsewhere_part is the panel's part for voice, or a call that is
// ringing, in a server that isn't shown: what and where, with the server's
// name, Show (which shows that server), and the way out or, for a call ringing
// in, Accept (which shows the server too) and Decline.
@(private = "file")
voice_elsewhere_part :: proc(ui: ^UI, e: Voice_Elsewhere) {
	ctx := &ui.ctx
	cmds := &e.ns.client.commands
	what, color := "", theme.connected
	switch e.state {
	case .Idle, .Elsewhere:
	case .Voice:
		what = "Voice connected"
	case .Call:
		what = "In a call"
	case .Ringing_In:
		what, color = "Incoming call", theme.ringing
	case .Ringing_Out:
		what, color = "Calling...", theme.ringing
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, color, fmt.tprintf("%s on %s", what, e.server), label_proc)
	if e.state == .Voice || e.state == .Call {
		mu.layout_row(ctx, {-60, 56})
		mu.label(ctx, e.where_)
		dim_label(ctx, call_length_shown(ui, e.since))
	} else {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, e.where_)
	}

	half := (mu.get_layout(ctx).body.w - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, -1})
	switch e.state {
	case .Idle, .Elsewhere:
	case .Ringing_In:
		accept, _, decline := answer_buttons(ui, "other")
		if accept {
			leave_voice_elsewhere(ui, e.ns)
			conn.push_command(cmds, conn.Call_Answer_Command{})
			ui.switch_to, ui.switching = e.ns, true
		}
		if decline {
			conn.push_command(cmds, conn.Call_Hangup_Command{})
		}
	case .Ringing_Out, .Voice, .Call:
		if .SUBMIT in stable_button(ctx, "other show", "Show", {.ALIGN_CENTER}) {
			ui.switch_to, ui.switching = e.ns, true
		}
		hint :=
			"Leave" if e.state == .Voice else ("Cancel" if e.state == .Ringing_Out else "Hang up")
		if hang_up_button(ui, "other leave", hint) {
			if e.state == .Voice {
				conn.push_command(cmds, conn.Voice_Command{})
			} else {
				conn.push_command(cmds, conn.Call_Hangup_Command{})
			}
		}
	}
}

// call_length_shown is how long it has been since `since`, as a call's length,
// requesting a frame for when the next second ticks over.
@(private = "file")
call_length_shown :: proc(ui: ^UI, since: time.Tick) -> string {
	d := time.tick_since(since)
	ui_redraw_in(ui, time.Second - d % time.Second)
	return conn.call_length(int(d / time.Second))
}
