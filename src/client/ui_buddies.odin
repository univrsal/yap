package client

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "common:proto"
import "client:platform"
import "client:settings"
import "client:render"

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
	// Something to tell about the conversation, and since when.
	notice:       string,
	notice_at:    time.Tick,
	// The file button was pressed: after the frame, the dialog opens for
	// a file to offer `pick_to` (ui_files_*.odin).
	pick:         bool,
	pick_to:      [proto.KEY_SIZE]u8,
	// When the server was last asked when the people in the list were
	// last here, and how many of them were online then: fewer now means
	// someone just left, and it's worth asking again.
	seen_asked:   time.Tick,
	seen_online:  int,
	// The delete button was pressed: the confirmation opens for the
	// conversation with `deleting` (delete_confirm).
	confirm:      bool,
	deleting:     [proto.KEY_SIZE]u8,
}

// Paste_Target is where a pasted image goes: the channel's chat, or a
// DM to `to`.
Paste_Target :: struct {
	dm: bool,
	to: [proto.KEY_SIZE]u8,
}

// How often the buddy screen asks when those who aren't here were last.
@(private = "file")
LAST_SEEN_REFRESH :: 30 * time.Second

// How long a notice under the conversation's header stays.
@(private = "file")
NOTICE_SHOW :: 5 * time.Second

// The confirmation before a conversation is deleted.
@(private = "file")
DELETE_CONFIRM :: "delete conversation"
@(private = "file")
DELETE_CONFIRM_WIDTH :: 260

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
		ui.buddies.seen_asked = {} // ask afresh when it opens
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
	   !settings.is_buddy(&ui.settings, ui.buddies.selected) &&
	   ui.buddies.selected not_in ui.view.dms {
		ui.buddies.has_selected = false
	}

	if narrow {
		mu.layout_row(ctx, {-1}, max(body.h / 3, 120))
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
	}
	ask_last_seen(ui)
	buddy_list_panel(ui)
	if narrow {
		mu.layout_row(ctx, {-1}, -1)
	}
	conversation(ui)
	user_menu(ui)
	delete_confirm(ui)
	app_audio_menu(ui)
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

	mu.layout_row(ctx, {render.ICON_SIZE + 4, -1})
	status_icon(ctx, .Buddies, ONLINE_COLOR if b.online != 0 else DIM_COLOR)

	mu.push_id(ctx, settings.user_key(b.key))
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
		u := settings.user_settings(&ui.settings, b.key)
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

	conv, have := &v.dms[key]
	// Their name, and the button that deletes what's been said.
	if have {
		mu.layout_row(ctx, {-(ICON_BUTTON + ctx.style.spacing * 2), ICON_BUTTON})
	} else {
		mu.layout_row(ctx, {-1})
	}
	mu.label(ctx, entry.name if entry.buddy else fmt.tprintf("%s  (not a buddy)", entry.name))
	if have &&
	   .SUBMIT in icon_button(ui, "dm delete", .Trash, "Delete this conversation", OFF_COLOR) {
		ui.buddies.confirm, ui.buddies.deleting = true, key
	}
	mu.layout_row(ctx, {-1})
	status := "here now" if entry.online != 0 else last_seen_text(ui, key)
	status_color := ONLINE_COLOR if entry.online != 0 else DIM_COLOR
	if t, ok := v.dm_typing[key]; ok && time.tick_since(t) < TYPING_SHOW {
		status = "typing..."
	}
	if ui.buddies.notice != "" && time.tick_since(ui.buddies.notice_at) < NOTICE_SHOW {
		status, status_color = ui.buddies.notice, OFF_COLOR
	}
	with_text_color(
		ctx,
		status_color,
		fmt.tprintf("%s  -  key %s...", status, settings.user_key(key)[:16]),
		label_proc,
	)

	// Leave room for the input row below, as the chat does.
	input_h := ctx.style.size.y + 2 * ctx.style.padding
	mu.layout_row(ctx, {-1}, -(input_h + ctx.style.spacing + 1))
	if have {
		// Open, so it's been seen.
		conv.unread = 0
		dm_panel(ui, conv, entry.name)
	} else {
		empty: View_Conversation
		dm_panel(ui, &empty, entry.name)
	}

	mu.layout_row(ctx, {-(2 * ICON_BUTTON + 10), ICON_BUTTON, ICON_BUTTON})
	// Ctrl+V could be an image, as in the chat box (chat_input); this
	// one goes to them.
	if !platform.WEB &&
	   ctx.focus_id == mu.get_id(ctx, uintptr(&ui.buddies.buf[0])) &&
	   .V in ctx.key_pressed_bits &&
	   .CTRL in ctx.key_down_bits &&
	   .ALT not_in ctx.key_down_bits {
		ctx.key_pressed_bits -= {.V}
		ui.chat.paste = true
		ui.paste_to = {
			dm = true,
			to = key,
		}
	}
	res := text_box(ui, ui.buddies.buf[:], &ui.buddies.len)
	box := ctx.last_id
	if .CHANGE in res && ui.buddies.len > 0 && ui.session != nil {
		push_command(&ui.session.client.commands, DM_Typing_Command{key})
	}
	send := .SUBMIT in res
	if .SUBMIT in icon_button(ui, "dm file", .File, "Send a file (archives, pictures, videos)") {
		if entry.online == 0 {
			ui.buddies.notice = "files only go to someone who's online"
			ui.buddies.notice_at = time.tick_now()
		} else {
			ui.buddies.pick, ui.buddies.pick_to = true, key
		}
	}
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
	push_command(&ui.session.client.commands, DM_Command{to = key, text = strings.clone(text)})
	ui.buddies.len = 0
}

/*
delete_confirm asks whether to delete the conversation the delete
button was pressed for, and does it: the history goes (dm_delete), and
the conversation closes. A buddy stays in the list, with nothing said
yet; anyone else leaves it. Clicking anywhere else is no. Call with the
View locked.
*/
@(private = "file")
delete_confirm :: proc(ui: ^UI) {
	ctx := &ui.ctx
	b := &ui.buddies
	if b.confirm {
		b.confirm = false
		mu.open_popup(ctx, DELETE_CONFIRM)
	}
	if cnt := mu.get_container(ctx, DELETE_CONFIRM, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, DELETE_CONFIRM) {
		return
	}
	defer mu.end_popup(ctx)

	key := b.deleting
	name := fingerprint(key)
	for e in buddy_list(&ui.settings, &ui.view) {
		if e.key == key {
			name = e.name
			break
		}
	}
	mu.layout_row(ctx, {DELETE_CONFIRM_WIDTH})
	mu.label(ctx, fmt.tprintf("Delete the conversation with %s?", name))
	mu.layout_row(ctx, {DELETE_CONFIRM_WIDTH}, 0)
	with_text_color(
		ctx,
		DIM_COLOR,
		"Every message in it is removed from this computer, for good. They keep their copy.",
		text_proc,
	)
	half := (DELETE_CONFIRM_WIDTH - ctx.style.spacing) / 2
	mu.layout_row(ctx, {half, half})
	if .SUBMIT in stable_button(ctx, "cancel", "Cancel") {
		mu.get_current_container(ctx).open = false
	}
	if .SUBMIT in stable_button(ctx, "delete", "Delete") {
		mu.get_current_container(ctx).open = false
		if ui.session != nil {
			log.debug("ui: delete a conversation")
			push_command(&ui.session.client.commands, Delete_DM_Command{with = key})
		}
		if b.has_selected && b.selected == key {
			b.has_selected = false
			b.len = 0
		}
	}
}

/*
ask_last_seen asks the server when those in the list who aren't here
were last: when the screen opens, every LAST_SEEN_REFRESH, and as soon
as someone in it leaves. Call with the View locked.
*/
@(private = "file")
ask_last_seen :: proc(ui: ^UI) {
	if ui.session == nil {
		return
	}
	cmd: Last_Seen_Command
	online := 0
	for b in buddy_list(&ui.settings, &ui.view) {
		if b.online != 0 {
			online += 1
		} else if cmd.count < len(cmd.keys) {
			cmd.keys[cmd.count] = b.key
			cmd.count += 1
		}
	}
	someone_left := online < ui.buddies.seen_online
	ui.buddies.seen_online = online
	due :=
		ui.buddies.seen_asked == {} || time.tick_since(ui.buddies.seen_asked) >= LAST_SEEN_REFRESH
	if cmd.count == 0 || !(due || someone_left) {
		return
	}
	ui.buddies.seen_asked = time.tick_now()
	push_command(&ui.session.client.commands, cmd)
}

// last_seen_text is what the conversation's header says about someone
// who isn't here: how long ago they were, as far as the server knows.
@(private = "file")
last_seen_text :: proc(ui: ^UI, key: [proto.KEY_SIZE]u8) -> string {
	seen, known := ui.view.last_seen[key]
	if !known || seen == proto.LAST_SEEN_HIDDEN {
		// The server only says to people who've sent each other DMs.
		return "not on this server right now"
	}
	if seen == 0 {
		return "not seen on this server yet"
	}
	ago := time.time_to_unix(time.now()) - i64(seen)
	plural :: proc(n: i64) -> string {
		return "" if n == 1 else "s"
	}
	switch {
	case ago < 60:
		return "last seen just now"
	case ago < 60 * 60:
		return fmt.tprintf("last seen %d minute%s ago", ago / 60, plural(ago / 60))
	case ago < 24 * 60 * 60:
		return fmt.tprintf("last seen %d hour%s ago", ago / 3600, plural(ago / 3600))
	case ago < 7 * 24 * 60 * 60:
		return fmt.tprintf("last seen %d day%s ago", ago / 86400, plural(ago / 86400))
	}
	return fmt.tprintf("last seen %s", chat_time(ui, seen))
}

/*
send_pasted_image sends an image that was pasted to where the paste was
meant for, taking it over. Images only go to someone who's online, and a
conversation with somebody who isn't says so instead. Call it outside
the View lock.
*/
send_pasted_image :: proc(ui: ^UI, target: Paste_Target, image: Chat_Image) {
	image := image
	if ui.session == nil {
		log.warn("not connected, so the pasted image wasn't sent")
		chat_image_destroy(&image)
		return
	}
	if !target.dm {
		push_command(&ui.session.client.commands, Chat_Image_Command{image})
		return
	}
	online := false
	{
		sync.guard(&ui.view.mutex)
		for _, u in ui.view.users {
			if u.key == target.to {
				online = true
			}
		}
	}
	if !online {
		ui.buddies.notice = "images only go to someone who's online"
		ui.buddies.notice_at = time.tick_now()
		chat_image_destroy(&image)
		return
	}
	push_command(&ui.session.client.commands, DM_Image_Command{to = target.to, image = image})
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}
