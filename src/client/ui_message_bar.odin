package client

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:richtext"
import "client:settings"
import "common:proto"

// The bar over a message. It is shown at the message's top right corner while
// the pointer is on the message, and offers to react to it, reply in its
// thread, edit it, pin or unpin it and delete it. Each action is only offered
// where it is allowed (the server checks again):
//
//   Recent   The emoji most often reacted with on this server
//            (settings.quick_reactions). An emoji is highlighted if we
//            already reacted with it, and clicking it takes our reaction
//            back. Custom emoji that the server no longer has are left out.
//   Reply    In the conversation's timeline (a thread's window already has
//            its composer).
//   Edit     Our own text messages.
//   Pin      Either participant in a DM, Pin_Messages in a channel. Replies in
//            a thread cannot be pinned.
//   Delete   Our own messages, or anyone's with Manage_Messages. The user is
//            asked first (the message menu asks, see ui_message_menu.odin)
//            unless Shift is held.
//
// The timelines find the message under the pointer while they lay out their
// messages (message_bar_track). The bar is drawn after all of them in a window
// of its own, so it is above the message (including in a thread window) and
// receives the pointer instead of the content below it. The bar reaches up
// over the message above, and stays with its own message while the pointer is
// on the bar.
//
// A touch screen has no pointer to hover with. Tapping a message shows its bar,
// which stays until something else or one of its buttons is tapped.

// Which message the bar is for.
Bar_Target :: struct {
	conv: proto.Conv_Id,
	slot: int, // its timeline: 0 for the conversation's, otherwise a thread window's
	id:   proto.Msg_Id,
}

UI_Message_Bar :: struct {
	// This frame's message, found while the timelines were laid out.
	found:        bool,
	target:       Bar_Target,
	msg:          conn.View_Message, // from the View, valid for this frame
	block:        mu.Rect, // where the message is
	clip:         mu.Rect, // the part of its timeline that is on screen
	host:         ^mu.Container, // the window its timeline is in
	panel:        ^mu.Container, // its timeline's panel, which the wheel scrolls over the bar
	// Where the bar was last frame, if it was shown.
	shown:        bool,
	shown_target: Bar_Target,
	rect:         mu.Rect,
	// The message tapped on a touch screen, whose bar stays visible, and
	// whether this frame's tap (UI.touch_tap) landed on a message.
	tapped:       Bar_Target,
	tap_claimed:  bool,
}

@(private = "file")
BAR_WINDOW :: "message bar"
// How far in from the message's right edge the bar sits.
@(private = "file")
BAR_INSET :: 6

// message_bar_track is called for each message a timeline lays out, with its
// rectangle in `block` and the timeline's panel as the current container. The
// message that the pointer is on (or that was tapped) is the one the bar is
// shown for in this frame.
message_bar_track :: proc(
	ui: ^UI,
	conv: proto.Conv_Id,
	slot: int,
	m: conn.View_Message,
	block: mu.Rect,
) {
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
		// On the bar, whose message below doesn't see the pointer.
		want = b.shown_target == t
	case:
		want = mu.mouse_over(ctx, block)
	}
	clip := mu.get_clip_rect(ctx)
	// Laid out, but outside the panel.
	if !want || mu.intersect_rects(block, clip).h <= 0 {
		return
	}
	mu.draw_rect(ctx, block, theme.hover_tint)
	b.found, b.target, b.msg, b.block, b.clip = true, t, m, block, clip
	b.panel = mu.get_current_container(ctx)
	b.host = nil
	for i := ctx.container_stack.idx - 1; i >= 0; i -= 1 {
		// Only a window has its `head` set (microui's in_hover_root).
		if c := ctx.container_stack.items[i]; c.head != nil {
			b.host = c
			break
		}
	}
}

// message_bar draws the bar for the message found by message_bar_track and
// handles its buttons. Call with the View locked, after every timeline of the
// frame.
message_bar :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	b := &ui.msg_bar
	defer {
		b.found, b.tap_claimed = false, false
		ui.touch_tap = false
	}
	// The wheel over the bar scrolls the timeline under it, as it does
	// everywhere else on the timeline: microui would give it to the bar, which
	// doesn't scroll. What microui takes as under the pointer is the window it
	// was over in the last frame, so this goes by that too: the bar moves
	// with the message under the pointer as the timeline scrolls, and in
	// between neither would take the wheel.
	if bar := mu.get_container(ctx, BAR_WINDOW);
	   bar != nil && ctx.hover_root == bar && b.panel != nil {
		ctx.scroll_target = b.panel
	}
	// A tap on neither a message nor the bar hides the tapped message's bar.
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
	rights := rights_here(v)
	reply := b.target.slot == 0
	edit := mine && .Edit in rights && m.kind == .Text && .Forwarded not_in m.flags
	pin := may_pin_here(v) && m.thread_root == 0
	del := (mine && .Delete in rights) || .Manage_Messages in v.permissions
	react := .React in rights
	recent := bar_recent_reactions(ui, m) if react else nil
	n := len(recent) + int(react) + int(reply) + int(edit) + int(pin) + int(del)
	if n == 0 {
		b.shown = false
		return
	}

	// At the message's top right, half over the line above, and kept on the
	// part of its timeline that is on screen.
	pad, spacing := ctx.style.padding, ctx.style.spacing
	row_h := ctx.style.size.y + 2 * pad
	w := i32(n) * icon_button_w(ctx) + i32(n - 1) * spacing + 2 * pad
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
	// Over the window its message is in (which may have been raised since),
	// but not over any window opened on top of that.
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
		bw = icon_button_w(ctx)
	}
	mu.layout_row(ctx, widths, row_h)
	cmds := &ui.session.client.commands
	done := false
	for r, i in recent {
		mu.push_id(ctx, uintptr(i))
		if recent_reaction_button(ui, r) {
			send_reaction(ui, m.id, r.emoji, !r.me)
			done = true
		}
		mu.pop_id(ctx)
	}
	if react && .SUBMIT in icon_button(ui, "react", .Smiley, "React") {
		open_picker(ui, m.id, r)
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
		if .SUBMIT in icon_button(ui, "pin", .Pin, hint, theme.pinned if pinned else {}) {
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

// One of the bar's recent reactions.
@(private = "file")
Recent_Reaction :: struct {
	emoji:  string, // as reacted with: ":name:" for a server's emoji, otherwise the characters
	custom: Maybe(int), // the index of the server's emoji
	me:     bool, // we have already reacted with it
}

// bar_recent_reactions are the most used reactions that the bar offers for `m`.
@(private = "file")
bar_recent_reactions :: proc(ui: ^UI, m: conn.View_Message) -> []Recent_Reaction {
	v := ui.view
	out := make([dynamic]Recent_Reaction, context.temp_allocator)
	for use in settings.quick_reactions(&ui.settings, v.server_key) {
		e := use.emoji
		r := Recent_Reaction {
			emoji = e,
		}
		if strings.has_prefix(e, ":") && strings.has_suffix(e, ":") && len(e) > 2 {
			index, ok := richtext.custom_emoji_index(v.emoji.names[:], e[1:len(e) - 1])
			if !ok {
				continue
			}
			r.custom = index
		}
		for have in m.reactions {
			if have.emoji == e {
				r.me = have.me
				break
			}
		}
		append(&out, r)
	}
	return out[:]
}

// recent_reaction_button is the button for a recent reaction: its emoji,
// highlighted if we already reacted with it, and its :name: below it.
@(private = "file")
recent_reaction_button :: proc(ui: ^UI, r: Recent_Reaction) -> bool {
	ctx := &ui.ctx
	id := mu.get_id(ctx, "recent")
	rect := mu.layout_next(ctx)
	mu.update_control(ctx, id, rect)
	keyed := nav_control(ctx, id, rect)
	if r.me {
		color := theme.highlight_more if ctx.hover_id == id else theme.highlight
		render.draw_rounded(ctx, rect, color, render.CONTROL_RADIUS)
	} else {
		mu.draw_control_frame(ctx, id, rect, .BUTTON)
	}
	if index, custom := r.custom.?; custom {
		if icon, ok := custom_emoji_icon(ui, index); ok {
			size: i32 = 20
			mu.draw_icon(
				ctx,
				icon,
				{rect.x + (rect.w - size) / 2, rect.y + (rect.h - size) / 2, size, size},
				{255, 255, 255, 255},
			)
		}
	} else {
		mu.draw_control_text(ctx, r.emoji, rect, .TEXT, {.ALIGN_CENTER})
	}
	if ctx.hover_id == id {
		name := r.emoji
		if r.custom == nil {
			first, _ := utf8.decode_rune_in_string(r.emoji)
			if index, ok := proto.emoji_index(first); ok {
				name = fmt.tprintf(":%s:", proto.emoji_name(proto.EMOJI[index]))
			}
		}
		ui.hint, ui.hint_of = name, rect
		hint_emoji_of(ui, r.emoji)
	}
	return ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id || keyed
}

// send_reaction adds (`on`) or removes our reaction to message `id`. A
// reaction that is added is also counted on this server, for the bar to offer
// the most used.
send_reaction :: proc(ui: ^UI, id: proto.Msg_Id, emoji: string, on: bool) {
	// Not where we may not react (the server would refuse it).
	if ui.session == nil || .React not_in rights_here(ui.view) {
		return
	}
	conn.push_command(
		&ui.session.client.commands,
		conn.React_Command{id = id, emoji = strings.clone(emoji), on = on},
	)
	server := ui.view.server_key
	if on && server != {} {
		settings.note_reaction(&ui.settings, server, emoji)
		ui.settings_dirty = true
	}
}
