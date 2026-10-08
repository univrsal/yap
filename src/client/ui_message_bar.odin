package client

import log "common:wlog"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
The bar over a message, at its top right corner while the pointer is on
it: react to it, reply in its thread, edit it, pin or unpin it, delete
it. Each is offered only where it's allowed (the server checks again):

	Reply    in the conversation's timeline (a thread's window has its
	         composer already)
	Edit     our own text messages
	Pin      either of the two in a DM, Pin_Messages in a channel; not a
	         reply in a thread
	Delete   our own, or anyone's with Manage_Messages; asked first (the
	         message menu asks, ui_message_menu.odin), unless Shift is
	         held

The timelines find the message under the pointer as they lay their
messages out (message_bar_track), and the bar is drawn after them all,
in a window of its own: so it's over the message, a thread window's
too, and has the pointer to itself rather than sharing it with what's
under it. The bar reaches up over the message above; while the pointer
is on it, it stays with its own.

A touch screen has no pointer to hover with: a tap on a message shows
its bar, which stays until something else is tapped or one of its
buttons is.
*/

// Which message the bar is for.
Bar_Target :: struct {
	conv: proto.Conv_Id,
	slot: int, // its timeline: 0 the conversation's, else a thread window's
	id:   proto.Msg_Id,
}

UI_Message_Bar :: struct {
	// This frame's message, found while the timelines were laid out.
	found:        bool,
	target:       Bar_Target,
	msg:          conn.View_Message, // the View's, good for this frame
	block:        mu.Rect, // where the message is
	clip:         mu.Rect, // what of its timeline is on screen
	host:         ^mu.Container, // the window its timeline is in
	// Where the bar was last frame, if it was there.
	shown:        bool,
	shown_target: Bar_Target,
	rect:         mu.Rect,
	// The message tapped on a touch screen, whose bar stays; and whether
	// this frame's tap (UI.touch_tap) landed on a message.
	tapped:       Bar_Target,
	tap_claimed:  bool,
}

@(private = "file")
BAR_WINDOW :: "message bar"
// How far in from the message's right edge the bar sits.
@(private = "file")
BAR_INSET :: 6
// The pin, lit while the message is pinned.
@(private = "file")
PINNED_COLOR :: mu.Color{120, 170, 240, 255}
// What the message the bar is for is lit with.
@(private = "file")
HOVER_COLOR :: mu.Color{255, 255, 255, 10}

/*
message_bar_track is told of each message a timeline lays out, in
`block`, with the timeline's panel the current container; the one the
pointer is on (or that was tapped) is the one the bar is for this frame.
*/
message_bar_track :: proc(ui: ^UI, conv: proto.Conv_Id, slot: int, m: conn.View_Message, block: mu.Rect) {
	ctx := &ui.ctx
	b := &ui.msg_bar
	t := Bar_Target{conv, slot, m.id}
	if ui.touch_tap && mu.mouse_over(ctx, block) {
		b.tapped, b.tap_claimed = t, true
	}
	want: bool
	switch {
	case .Deleted in m.flags || message_menu_open(ui):
	case b.tapped != {}:
		want = b.tapped == t
	case b.shown && mu.rect_overlaps_vec2(b.rect, ctx.mouse_pos):
		// On the bar, which the message under it doesn't see the pointer
		// through.
		want = b.shown_target == t
	case:
		want = mu.mouse_over(ctx, block)
	}
	clip := mu.get_clip_rect(ctx)
	// Laid out, but off the panel.
	if !want || mu.intersect_rects(block, clip).h <= 0 {
		return
	}
	mu.draw_rect(ctx, block, HOVER_COLOR)
	b.found, b.target, b.msg, b.block, b.clip = true, t, m, block, clip
	b.host = nil
	for i := ctx.container_stack.idx - 1; i >= 0; i -= 1 {
		// Only a window has its `head` set (microui's in_hover_root).
		if c := ctx.container_stack.items[i]; c.head != nil {
			b.host = c
			break
		}
	}
}

/*
message_bar draws the bar for the message message_bar_track found, and
does what's pressed on it. Call with the View locked, after every
timeline of the frame.
*/
message_bar :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	b := &ui.msg_bar
	defer {
		b.found, b.tap_claimed = false, false
		ui.touch_tap = false
	}
	// A tap on neither a message nor the bar lets the tapped one go.
	if ui.touch_tap &&
	   !b.tap_claimed &&
	   !(b.shown && mu.rect_overlaps_vec2(b.rect, ctx.mouse_pos)) &&
	   b.tapped != {} {
		b.tapped, b.found = {}, false
	}
	if !b.found || ui.session == nil || b.target.conv != v.viewing {
		b.shown = false
		return
	}
	m := b.msg
	mine := m.sender == v.me
	reply := b.target.slot == 0
	edit := mine && m.kind == .Text && .Forwarded not_in m.flags
	pin := may_pin_here(v) && m.thread_root == 0
	del := mine || .Manage_Messages in v.permissions
	n := 1 + int(reply) + int(edit) + int(pin) + int(del)

	// At the message's top right, half over the line above it, and kept
	// on the part of its timeline that's on screen.
	pad, spacing := ctx.style.padding, ctx.style.spacing
	row_h := ctx.style.size.y + 2 * pad
	w := i32(n) * ICON_BUTTON + i32(n - 1) * spacing + 2 * pad
	h := row_h + 2 * pad
	right := min(b.block.x + b.block.w, b.clip.x + b.clip.w) - BAR_INSET
	x := max(right - w, b.clip.x)
	y := clamp(b.block.y - h / 2, b.clip.y, max(b.clip.y + b.clip.h - h, b.clip.y))
	r := mu.Rect{x, y, w, h}

	cnt := mu.get_container(ctx, BAR_WINDOW)
	if cnt == nil {
		b.shown = false
		return
	}
	cnt.rect = r
	// Over the window its message is in (which may have been raised
	// since), but not over whatever has been opened over that.
	if b.host != nil && cnt.zindex <= b.host.zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(ctx, BAR_WINDOW, r, {.NO_TITLE, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE}) {
		b.shown = false
		return
	}
	defer mu.end_window(ctx)
	b.shown, b.shown_target, b.rect = true, b.target, r

	widths := make([]i32, n, context.temp_allocator)
	for &bw in widths {
		bw = ICON_BUTTON
	}
	mu.layout_row(ctx, widths, row_h)
	cmds := &ui.session.client.commands
	done := false
	if .SUBMIT in icon_button(ui, "react", .Smiley, "React") {
		open_picker(ui, m.id)
		done = true
	}
	if reply && .SUBMIT in icon_button(ui, "reply", .Reply, "Reply in thread") {
		open_thread(ui, {b.target.conv, m.thread_root if m.thread_root != 0 else m.id})
		done = true
	}
	if edit && .SUBMIT in icon_button(ui, "edit", .Edit, "Edit") {
		start_editing(ui, m.id, m.text, composer_of(ui, b.target.slot))
		done = true
	}
	if pin {
		pinned := .Pinned in m.flags
		hint := "Unpin" if pinned else "Pin"
		if .SUBMIT in icon_button(ui, "pin", .Pin, hint, PINNED_COLOR if pinned else {}) {
			conn.push_command(cmds, conn.Pin_Command{id = m.id, on = !pinned})
			done = true
		}
	}
	if del && .SUBMIT in icon_button(ui, "delete", .Trash, "Delete (Shift: without asking)") {
		if .SHIFT in ctx.key_down_bits {
			conn.push_command(cmds, conn.Delete_Command{id = m.id})
			log.debug("ui: delete a message")
		} else {
			open_message_menu(ui, m, b.target.slot, confirm_delete = true)
		}
		done = true
	}
	if done {
		b.tapped = {}
	}
}
