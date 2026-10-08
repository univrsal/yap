package client

import log "common:wlog"
import "core:fmt"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:settings"
import "common:proto"

/*
The buddy screen (buddies.odin): the buddy list on the left, with
anyone else we have a DM with, and the DM with whoever's picked on the
right, drawn by the same timeline as a channel's (ui_timeline.odin).
It's there while connected, opened and closed by the buddies button
along the top, which it shares with the session screen.

The network side looks at one conversation at a time: while this screen
shows a DM, that's the one, and going back to the channels goes back to
the channel that was being looked at (keep_viewing).
*/

UI_Buddies :: struct {
	// Whose DM is open; 0 for nobody.
	selected:     proto.Account_Id,
	// What's being written to them.
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it's written in
	// Something to tell about the conversation, and since when.
	notice:       string,
	notice_at:    time.Tick,
	// The file button was pressed: after the frame, the dialog opens for
	// a file to offer `pick_to` (ui_files_*.odin).
	pick:         bool,
	pick_to:      proto.Account_Id,
	// Files to go with the next message (ui_attachments.odin).
	files:        [dynamic]Picked_File,
	// When the server was last asked when the people in the list were
	// last here, and how many of them were online then: fewer now means
	// someone just left, and it's worth asking again.
	seen_asked:   time.Tick,
	seen_online:  int,
	// The message of ours being edited, 0 for none, and its conversation
	// (ui_message_menu.odin).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	// The conversation the network side was last asked to look at, and
	// when (keep_viewing).
	view_asked:   proto.Conv_Id,
	view_back:    bool,
	view_at:      time.Tick,
}

// How often the buddy screen asks when those who aren't here were last.
@(private = "file")
LAST_SEEN_REFRESH :: 30 * time.Second

// How long a notice under the conversation's header stays.
@(private = "file")
NOTICE_SHOW :: 5 * time.Second

// How long to wait for the network side to look at what it was asked
// to before asking again.
@(private = "file")
VIEW_RETRY :: time.Second

// The buddy list's colours: a buddy who's here, and one who isn't.
@(private = "file")
ONLINE_COLOR :: SPEAKING_COLOR

// buddies_button opens the buddy screen, or goes back from it. It
// lights up for DMs that haven't been read.
buddies_button :: proc(ui: ^UI) {
	open := ui.page == .Buddies
	unread := dm_unread(&ui.settings, ui.view)
	hint := "Back to the channels" if open else "Buddies"
	color := CHAT_NAME_COLOR if open else mu.Color{}
	if unread > 0 && !open {
		hint = fmt.tprintf("Buddies (%s unread)", conn.unread_count(unread))
		color = SPEAKING_COLOR
	}
	if .SUBMIT in icon_button(ui, "buddies", .Mail, hint, color) {
		ui.page = .Main if open else .Buddies
		ui.buddies.seen_asked = {} // ask afresh when it opens
	}
}

// open_conversation shows the buddy screen with the DM with `account`.
open_conversation :: proc(ui: ^UI, account: proto.Account_Id) {
	ui.page = .Buddies
	if ui.buddies.selected != account {
		ui.buddies.len = 0
	}
	ui.buddies.selected = account
}

/*
keep_viewing has the network side look at `conv` (with `back`, the
channel it was looking at before a DM), if it isn't: once, and again
only if that doesn't come about. Call with the View locked.
*/
keep_viewing :: proc(ui: ^UI, conv: proto.Conv_Id, back := false) {
	v := ui.view
	b := &ui.buddies
	if ui.session == nil {
		return
	}
	want := v.channel if back else conv
	if v.viewing == want && (want != 0 || !back) {
		b.view_asked, b.view_back = want, back
		return
	}
	if b.view_asked == want && b.view_back == back && time.tick_since(b.view_at) < VIEW_RETRY {
		ui_redraw_at(ui, time.tick_add(b.view_at, VIEW_RETRY)) // to ask again
		return
	}
	b.view_asked, b.view_back, b.view_at = want, back, time.tick_now()
	ui_redraw_in(ui, VIEW_RETRY)
	conn.push_command(&ui.session.client.commands, conn.View_Command{conv = conv, back = back})
}

// back_from_dms is the session screen making sure what it shows is a
// channel's: coming back from the buddy screen, or having been sent
// there by something else. Call with the View locked.
back_from_dms :: proc(ui: ^UI) {
	v := ui.view
	if v.viewing == 0 && v.channel == 0 {
		return // not told of any yet
	}
	if v.viewing == 0 || viewed_channel(v) == nil {
		keep_viewing(ui, 0, back = true)
	}
}

// buddies_screen lays the screen out, like session_screen: side by
// side, or the list over the conversation in a narrow window. Call with
// the View locked.
buddies_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	body := mu.get_current_container(ctx).body
	narrow := body.w < NARROW_LAYOUT

	session_header(ui)

	list := buddy_list(&ui.settings, ui.view)
	// Somebody who's left the list (taken off it, or no buddy any more
	// and no DM) takes the conversation along.
	entry: Buddy_Entry
	found := false
	for e in list {
		if e.account == ui.buddies.selected {
			entry, found = e, true
		}
	}
	if !found && ui.buddies.selected != 0 {
		if ui.buddies.selected in ui.view.accounts && ui.buddies.selected != ui.view.me {
			// Picked from somewhere else (a channel's member list).
			entry, found = buddy_entry(ui.view, ui.buddies.selected, false), true
		} else {
			ui.buddies.selected = 0
		}
	}
	keep_viewing(ui, entry.conv if found else 0)

	// The list over the voice panel; in a narrow window, the list, the
	// conversation and the panel one over the other.
	panel_h := voice_panel_height(ui)
	if narrow {
		mu.layout_row(ctx, {-1}, max(body.h / 3, 120))
	} else {
		mu.layout_row(ctx, {280, -1}, -1)
	}
	ask_last_seen(ui, list)
	if narrow {
		buddy_list_panel(ui, list)
		mu.layout_row(ctx, {-1}, -(panel_h + 1))
	} else {
		mu.layout_begin_column(ctx)
		mu.layout_row(ctx, {-1}, -(panel_h + 1))
		buddy_list_panel(ui, list)
		voice_panel(ui)
		mu.layout_end_column(ctx)
	}
	conversation(ui, entry, found)
	if narrow {
		voice_panel(ui)
	}
	user_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
}

@(private = "file")
buddy_list_panel :: proc(ui: ^UI, list: []Buddy_Entry) {
	ctx := &ui.ctx

	mu.begin_panel(ctx, "buddies")
	defer mu.end_panel(ctx)

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

	pic := ctx.text_height(ctx.style.font) + 2
	mu.layout_row(ctx, {pic + 4, -1})
	cell := mu.layout_next(ctx)
	avatar(ui, b.account, {cell.x, cell.y + (cell.h - pic) / 2, pic, pic})

	mu.push_id(ctx, uintptr(b.account))
	defer mu.pop_id(ctx)
	id := mu.get_id(ctx, "buddy")
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	selected := ui.buddies.selected == b.account
	switch {
	case selected:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_FOCUS])
	case ctx.hover_id == id:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
	}
	color := ctx.style.colors[.TEXT] if b.online else DIM_COLOR
	text := b.name
	if b.unread > 0 {
		text = fmt.tprintf("%s  (%s)", b.name, conn.unread_count(b.unread))
		color = SPEAKING_COLOR
	}
	acc := ui.view.accounts[b.account] or_else {}
	name_and_status(ctx, r, text, color, status_line(acc))

	if ctx.hover_id != id {
		return
	}
	switch {
	case ctx.mouse_pressed_bits == {.LEFT}:
		open_conversation(ui, b.account)
	case .RIGHT in ctx.mouse_pressed_bits:
		open_user_menu(ui, 0, b.account)
	}
}

// conversation is the right-hand side: who it's with, the messages,
// and the box to write in.
@(private = "file")
conversation :: proc(ui: ^UI, entry: Buddy_Entry, found: bool) {
	ctx := &ui.ctx
	v := ui.view

	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)

	if !found {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, DIM_COLOR, "Pick a buddy to talk to them.", label_proc)
		return
	}
	account := entry.account

	// Their name, and the button that takes a DM off the list (somebody
	// who isn't a buddy, where there's something to take off).
	can_hide := entry.conv != 0 && !entry.buddy
	switch {
	case entry.conv == 0:
		mu.layout_row(ctx, {-(ICON_BUTTON + ctx.style.spacing * 2), ICON_BUTTON})
	case can_hide:
		mu.layout_row(
			ctx,
			{
				-(ICON_BUTTON + 3 * ICON_BUTTON + ctx.style.spacing * 5),
				ICON_BUTTON,
				ICON_BUTTON,
				ICON_BUTTON,
				ICON_BUTTON,
			},
		)
	case:
		mu.layout_row(
			ctx,
			{
				-(ICON_BUTTON + 2 * ICON_BUTTON + ctx.style.spacing * 4),
				ICON_BUTTON,
				ICON_BUTTON,
				ICON_BUTTON,
			},
		)
	}
	deleted := .Deleted in (v.accounts[account] or_else {}).flags
	mu.label(
		ctx,
		entry.name if entry.buddy || deleted else fmt.tprintf("%s  (not a buddy)", entry.name),
	)
	// Calling them, while they're here and we're in no call.
	if !deleted && may_call(v, account) {
		if .SUBMIT in icon_button(ui, "dm call", .Phone, "Call") {
			call_account(ui, account)
		}
	} else {
		mu.label(ctx, "")
	}
	if entry.conv != 0 {
		pins_button(ui)
		search_button(ui)
	}
	if can_hide &&
	   .SUBMIT in
		   icon_button(
			   ui,
			   "dm hide",
			   .Trash,
			   "Take this conversation off the list until something new is said in it",
			   OFF_COLOR,
		   ) {
		last: proto.Msg_Id
		for dm in v.dms {
			if dm.id == entry.conv {
				last = dm.last
			}
		}
		settings.hide_dm(&ui.settings, v.server_key, entry.conv, max(last, 1))
		shared_hidden_changed(ui, entry.conv, max(last, 1))
		ui.settings_dirty = true
		ui.buddies.selected = 0
		log.debug("ui: hid a conversation")
		return
	}
	mu.layout_row(ctx, {-1})
	if deleted {
		// What's there can be read, and nothing more said (the server
		// refuses it too).
		with_text_color(
			ctx,
			DIM_COLOR,
			"Their account was deleted: this conversation can be read, but not written to.",
			label_proc,
		)
		mu.layout_row(ctx, {-1}, -1)
		if entry.conv != 0 && v.viewing == entry.conv {
			timeline(ui, &ui.timeline, {entry.conv, 0}, readonly = true)
		}
		return
	}
	status := "here now" if entry.online else last_seen_text(ui, account)
	status_color := ONLINE_COLOR if entry.online else DIM_COLOR
	if entry.conv != 0 && conn.is_typing(v, account, entry.conv) {
		status = "typing..."
	} else if entry.conv != 0 && conn.is_typing_in_thread(v, account, entry.conv) {
		status = "typing in a thread..."
	}
	if ui.paste != nil {
		status = "reading the clipboard..."
	}
	if editing := composer_status(composer_of_page(ui)); editing != "" {
		status, status_color = editing, DIM_COLOR
	}
	if notice, ok, fresh := fresh_notice(v); fresh && !ok {
		status, status_color = notice, OFF_COLOR
	}
	if ui.buddies.notice != "" && time.tick_since(ui.buddies.notice_at) < NOTICE_SHOW {
		status, status_color = ui.buddies.notice, OFF_COLOR
		ui_redraw_at(ui, time.tick_add(ui.buddies.notice_at, NOTICE_SHOW))
	}
	with_text_color(ctx, status_color, status, label_proc)

	// Leave room for the input row below, as the chat does.
	input_h := composer_height(ui, composer_of_page(ui))
	files_h := composer_files_height(ui, composer_of_page(ui), panel_width(ctx))
	mu.layout_row(ctx, {-1}, -(input_h + files_h + ctx.style.spacing + 1))
	if entry.conv != 0 && v.viewing == entry.conv {
		timeline(ui, &ui.timeline, {entry.conv, 0})
	} else {
		no_conversation_yet(ui, entry)
	}

	composer := composer_of_page(ui)
	composer_files(ui, composer, panel_width(ctx))
	composer_row(ui, input_h, 5)
	completion_keys(ui, composer)
	composer_keys(ui, composer)
	res, box := composer_box(ui, composer)
	completion_update(ui, composer)
	if .CHANGE in res &&
	   ui.buddies.len > 0 &&
	   ui.session != nil &&
	   v.viewing == entry.conv &&
	   entry.conv != 0 &&
	   ui.buddies.editing == 0 {
		conn.push_command(&ui.session.client.commands, conn.Typing_Command{})
	}
	send := .SUBMIT in res
	composer_buttons(ui, input_h, 5)
	attach_button(ui, composer)
	emoji_button(ui, composer)
	preview_button(ui, composer)
	if .SUBMIT in icon_button(ui, "dm file", .File, "Send a file (archives, pictures, videos)") {
		if !entry.online {
			ui.buddies.notice = "files only go to someone who's here"
			ui.buddies.notice_at = time.tick_now()
		} else {
			ui.buddies.pick, ui.buddies.pick_to = true, account
		}
	}
	if .SUBMIT in
	   icon_button(
		   ui,
		   "dm send",
		   .Send,
		   "Save" if ui.buddies.editing != 0 else "Enter: Send\nCtrl+Enter: New line",
	   ) {
		send = true
	}
	mu.layout_end_column(ctx)
	if !send {
		return
	}
	// Enter takes the focus away from the box; keep typing instead.
	mu.set_focus(ctx, box)
	composer_send(ui, composer, account)
}

// no_conversation_yet stands in for the timeline where there's no DM
// yet (or it's on its way): what we've written to them, going out.
@(private = "file")
no_conversation_yet :: proc(ui: ^UI, entry: Buddy_Entry) {
	ctx := &ui.ctx
	mu.begin_panel(ctx, "no conversation")
	defer mu.end_panel(ctx)
	pending := 0
	for p, i in ui.view.outbox {
		if p.dm_to == entry.account && (p.conv == 0 || p.conv == entry.conv) {
			pending_message(ui, p, i64(i) * ITEMS_PER_MESSAGE)
			pending += 1
		}
	}
	if pending > 0 {
		return
	}
	mu.layout_row(ctx, {-1})
	text :=
		"Loading messages..." if entry.conv != 0 else fmt.tprintf("Nothing said with %s yet.", entry.name)
	with_text_color(ctx, CHAT_DIM_COLOR, text, label_proc)
}

/*
ask_last_seen asks the server when those in the list who aren't here
were last: when the screen opens, every LAST_SEEN_REFRESH, and as soon
as someone in it leaves. Call with the View locked.
*/
@(private = "file")
ask_last_seen :: proc(ui: ^UI, list: []Buddy_Entry) {
	if ui.session == nil {
		return
	}
	cmd: conn.Last_Seen_Command
	online := 0
	for b in list {
		if b.online {
			online += 1
		} else if cmd.count < len(cmd.accounts) {
			cmd.accounts[cmd.count] = b.account
			cmd.count += 1
		}
	}
	someone_left := online < ui.buddies.seen_online
	ui.buddies.seen_online = online
	due :=
		ui.buddies.seen_asked == {} || time.tick_since(ui.buddies.seen_asked) >= LAST_SEEN_REFRESH
	if cmd.count == 0 || !(due || someone_left) {
		if cmd.count != 0 {
			ui_redraw_at(ui, time.tick_add(ui.buddies.seen_asked, LAST_SEEN_REFRESH))
		}
		return
	}
	ui.buddies.seen_asked = time.tick_now()
	ui_redraw_in(ui, LAST_SEEN_REFRESH)
	conn.push_command(&ui.session.client.commands, cmd)
}

// last_seen_text is what the conversation's header says about someone
// who isn't here: how long ago they were, as far as the server says.
last_seen_text :: proc(ui: ^UI, account: proto.Account_Id) -> string {
	seen, known := ui.view.last_seen[account]
	if !known || seen == proto.LAST_SEEN_HIDDEN || seen == 0 {
		// The server only says to people who've written to each other.
		return ""
	}
	ago := (time.time_to_unix_nano(time.now()) / 1_000_000 - i64(seen)) / 1000
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
	return fmt.tprintf("last seen %s", chat_time(ui, proto.Unix_Time(i64(seen) / 1000)))
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}
