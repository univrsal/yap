package client

import log "../common/wlog"
import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"

import "../proto"

/*
The buddy screen (buddies.odin): the buddy list on the left, with
anyone else we have a conversation with, and the conversation with
whoever's picked on the right (dm.odin). It's there while connected,
opened and closed by the buddies button along the top, which it shares
with the session screen.
*/

UI_Buddies :: struct {
	// Whose conversation is open.
	selected:     [proto.KEY_SIZE]u8,
	has_selected: bool,
	// What's being written to them.
	buf:          [proto.MAX_DM_SIZE]u8,
	len:          int,
	// The open conversation's View_Conversation.changes when it was last
	// scrolled to the bottom.
	scrolled:     int,
}

// The buddy list's colours: a buddy who's here, and one who isn't.
@(private = "file")
ONLINE_COLOR :: SPEAKING_COLOR

// buddies_button opens the buddy screen, or goes back from it. It
// lights up for DMs that haven't been seen.
buddies_button :: proc(ui: ^UI) {
	open := ui.page == .Buddies
	unread := dm_unread(&ui.view)
	hint := "Back to the channels" if open else "Buddies"
	color := CHAT_NAME_COLOR if open else mu.Color{}
	if unread > 0 && !open {
		hint = fmt.tprintf("Buddies (%d new message%s)", unread, "" if unread == 1 else "s")
		color = SPEAKING_COLOR
	}
	if .SUBMIT in icon_button(ui, "buddies", .Buddies, hint, color) {
		ui.page = .Main if open else .Buddies
	}
}

// open_conversation shows the buddy screen with `key`'s conversation.
open_conversation :: proc(ui: ^UI, key: [proto.KEY_SIZE]u8) {
	ui.page = .Buddies
	if !ui.buddies.has_selected || ui.buddies.selected != key {
		ui.buddies.len = 0
		ui.buddies.scrolled = -1 // start at the newest
	}
	ui.buddies.selected, ui.buddies.has_selected = key, true
}

// buddies_screen lays the screen out, like session_screen: side by
// side, or the list over the conversation in a narrow window. Call with
// the View locked.
buddies_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	body := mu.get_current_container(ctx).body
	narrow := body.w < NARROW_LAYOUT

	session_header(ui)

	// Someone removed as a buddy, with no conversation to keep them in
	// the list, takes it along.
	if ui.buddies.has_selected &&
	   !is_buddy(&ui.settings, ui.buddies.selected) &&
	   ui.buddies.selected not_in ui.view.dms {
		ui.buddies.has_selected = false
	}

	if narrow {
		mu.layout_row(ctx, {-1}, max(body.h / 3, 120))
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
	}
	buddy_list_panel(ui)
	if narrow {
		mu.layout_row(ctx, {-1}, -1)
	}
	conversation(ui)
	user_menu(ui)
}

@(private = "file")
buddy_list_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.begin_panel(ctx, "buddies")
	defer mu.end_panel(ctx)

	list := buddy_list(&ui.settings, v)
	if len(list) == 0 {
		mu.layout_row(ctx, {-1}, -1)
		with_text_color(
			ctx,
			DIM_COLOR,
			"No buddies yet. Click someone in the channel list and add them from the menu.",
			text_proc,
		)
		return
	}
	for b in list {
		buddy_row(ui, b)
	}
}

/*
buddy_row is one buddy in the list: a flat, full-width control like the
channel list's rows. A left click opens their conversation, a right
click the same menu as clicking them in a channel.
*/
@(private = "file")
buddy_row :: proc(ui: ^UI, b: Buddy_Entry) {
	ctx := &ui.ctx

	mu.layout_row(ctx, {ICON_SIZE + 4, -1})
	status_icon(ctx, .Buddies, ONLINE_COLOR if b.online != 0 else DIM_COLOR)

	mu.push_id(ctx, user_key(b.key))
	defer mu.pop_id(ctx)
	id := mu.get_id(ctx, "buddy")
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	selected := ui.buddies.has_selected && ui.buddies.selected == b.key
	switch {
	case selected:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_FOCUS])
	case ctx.hover_id == id:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
	}
	saved := ctx.style.colors[.TEXT]
	if b.online == 0 {
		ctx.style.colors[.TEXT] = DIM_COLOR
	}
	text := b.name
	if b.unread > 0 {
		text = fmt.tprintf("%s  (%d)", b.name, b.unread)
		ctx.style.colors[.TEXT] = SPEAKING_COLOR
	}
	mu.draw_control_text(ctx, text, r, .TEXT)
	ctx.style.colors[.TEXT] = saved

	if ctx.hover_id != id {
		return
	}
	switch {
	case ctx.mouse_pressed_bits == {.LEFT}:
		open_conversation(ui, b.key)
	case .RIGHT in ctx.mouse_pressed_bits:
		u := user_settings(&ui.settings, b.key)
		ui.menu_user = b.online
		ui.menu_key = b.key
		ui.menu_volume = u.volume * 100
		ui.menu_requested = true
	}
}

// conversation is the right-hand side: who it's with, the messages,
// and the box to write in.
@(private = "file")
conversation :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)

	if !ui.buddies.has_selected {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "Pick a buddy to talk to them.", label_proc)
		return
	}
	key := ui.buddies.selected
	entry: Buddy_Entry
	for b in buddy_list(&ui.settings, v) {
		if b.key == key {
			entry = b
			break
		}
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, entry.name if entry.buddy else fmt.tprintf("%s  (not a buddy)", entry.name))
	mu.layout_row(ctx, {-1})
	status := "here now" if entry.online != 0 else "not on this server right now"
	status_color := ONLINE_COLOR if entry.online != 0 else DIM_COLOR
	if t, ok := v.dm_typing[key]; ok && time.tick_since(t) < TYPING_SHOW {
		status = "typing..."
	}
	with_text_color(
		ctx,
		status_color,
		fmt.tprintf("%s  -  key %s...", status, user_key(key)[:16]),
		label_proc,
	)

	// Leave room for the input row below, as the chat does.
	input_h := ctx.style.size.y + 2 * ctx.style.padding
	mu.layout_row(ctx, {-1}, -(input_h + ctx.style.spacing + 1))
	conv, have := &v.dms[key]
	if have {
		// Open, so it's been seen.
		conv.unread = 0
		dm_panel(ui, conv, entry.name)
	} else {
		empty: View_Conversation
		dm_panel(ui, &empty, entry.name)
	}

	mu.layout_row(ctx, {-(ICON_BUTTON + 6), ICON_BUTTON})
	res := text_box(ui, ui.buddies.buf[:], &ui.buddies.len)
	box := ctx.last_id
	if .CHANGE in res && ui.buddies.len > 0 && ui.session != nil {
		push_command(&ui.session.client.commands, DM_Typing_Command{key})
	}
	send := .SUBMIT in res
	if .SUBMIT in icon_button(ui, "dm send", .Send, "Send") {
		send = true
	}
	if !send {
		return
	}
	// Enter takes the focus away from the box; keep typing instead.
	mu.set_focus(ctx, box)
	text := strings.trim_space(string(ui.buddies.buf[:ui.buddies.len]))
	if text == "" || ui.session == nil {
		return
	}
	log.debug("ui: direct message")
	push_command(
		&ui.session.client.commands,
		DM_Command{to = key, text = strings.clone(text)},
	)
	ui.buddies.len = 0
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}
