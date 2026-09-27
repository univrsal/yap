package client

import log "../common/wlog"
import "core:fmt"
import mu "vendor:microui"

import "../proto"

/*
The buddy screen (buddies.odin): the buddy list on the left, and the
conversation with whoever's picked on the right. It's there while
connected, opened and closed by the buddies button along the top, which
it shares with the session screen.

Direct messages don't exist yet, so the conversation is only its frame:
who it's with, whether they're here, and a box to write in.
*/

UI_Buddies :: struct {
	// Whose conversation is open.
	selected:     [proto.KEY_SIZE]u8,
	has_selected: bool,
	// What's being written to them.
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
}

// The buddy list's colours: a buddy who's here, and one who isn't.
@(private = "file")
ONLINE_COLOR :: SPEAKING_COLOR

// buddies_button opens the buddy screen, or goes back from it.
buddies_button :: proc(ui: ^UI) {
	open := ui.page == .Buddies
	if .SUBMIT in
	   icon_button(
		   ui,
		   "buddies",
		   .Buddies,
		   "Back to the channels" if open else "Buddies",
		   CHAT_NAME_COLOR if open else mu.Color{},
	   ) {
		ui.page = .Main if open else .Buddies
	}
}

// open_conversation shows the buddy screen with `key`'s conversation.
open_conversation :: proc(ui: ^UI, key: [proto.KEY_SIZE]u8) {
	ui.page = .Buddies
	if !ui.buddies.has_selected || ui.buddies.selected != key {
		ui.buddies.len = 0
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

	// A buddy removed while their conversation was open takes it along.
	if ui.buddies.has_selected && !is_buddy(&ui.settings, ui.buddies.selected) {
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
	mu.draw_control_text(ctx, b.name, r, .TEXT)
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

// conversation is the right-hand side: who it's with, where the
// messages will go, and the box to write in.
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
	mu.label(ctx, entry.name)
	mu.layout_row(ctx, {-1})
	status := "here now" if entry.online != 0 else "not on this server right now"
	with_text_color(
		ctx,
		ONLINE_COLOR if entry.online != 0 else DIM_COLOR,
		fmt.tprintf("%s  -  key %s...", status, user_key(key)[:16]),
		label_proc,
	)

	// Leave room for the input row below, as the chat does.
	input_h := ctx.style.size.y + 2 * ctx.style.padding
	mu.layout_row(ctx, {-1}, -(input_h + ctx.style.spacing + 1))
	mu.begin_panel(ctx, "conversation")
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, DIM_COLOR, "Direct messages aren't here yet.", label_proc)
	mu.end_panel(ctx)

	mu.layout_row(ctx, {-(ICON_BUTTON + 6), ICON_BUTTON})
	send := .SUBMIT in text_box(ui, ui.buddies.buf[:], &ui.buddies.len)
	if .SUBMIT in icon_button(ui, "dm send", .Send, "Send (not yet: direct messages aren't here yet)") {
		send = true
	}
	if send {
		log.debug("ui: direct messages aren't implemented yet")
	}
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}
