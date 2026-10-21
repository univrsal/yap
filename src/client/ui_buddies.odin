package client

import log "common:wlog"
import "core:fmt"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:settings"
import "common:proto"

// The inbox, or buddy screen (see buddies.odin): on the left, the buddies and
// anyone else we have a DM with, on every server we're logged in to, in
// two sections. On the right, the DM with whoever is picked, drawn by the
// same timeline as a channel's (see ui_timeline.odin). It is opened and closed
// by the inbox's icon at the top of the rail (see ui_servers.odin).
//
// A DM is on one server, so picking one on another server shows that
// server (see switch_now) behind the inbox. What is open is always the shown
// server's, as everything else about the conversation is.
//
// The network side looks at one conversation at a time. While this screen
// shows a DM, that is the conversation it looks at, and going back to the
// channels goes back to the channel that was being looked at (see keep_viewing).

UI_Buddies :: struct {
	// Whose DM is open, 0 for nobody.
	selected:     proto.Account_Id,
	// What is being written to them.
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it is written in
	// Something to tell the user about the conversation, and since when.
	notice:       string,
	notice_at:    time.Tick,
	// The file button was pressed. After the frame, the dialog opens to pick
	// a file to offer to `pick_to` (see ui_files_*.odin).
	pick:         bool,
	pick_to:      proto.Account_Id,
	// Files to go with the next message (see ui_attachments.odin).
	files:        [dynamic]Picked_File,
	// The message of ours that is being edited (0 for none) and its conversation
	// (see ui_message_menu.odin).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	// The conversation the network side was last asked to look at, and
	// when (see keep_viewing).
	view_asked:   proto.Conv_Id,
	view_back:    bool,
	view_at:      time.Tick,
}

// How often the inbox asks when the people who aren't online were last seen.
@(private = "file")
LAST_SEEN_REFRESH :: 30 * time.Second

// How long a notice under the conversation's header stays.
@(private = "file")
NOTICE_SHOW :: 5 * time.Second

// How long to wait for the network side to look at what it was asked
// to before asking again.
@(private = "file")
VIEW_RETRY :: time.Second

// toggle_inbox opens the inbox, or goes back from it to the shown
// server's channels.
toggle_inbox :: proc(ui: ^UI) {
	if ui.page == .Buddies {
		ui.page = .Main
		return
	}
	ui.page = .Buddies
	for ns in ui.sessions {
		ns.seen_asked = {} // ask again when it opens
	}
	// In a narrow window it opens on the list (see buddies_screen).
	if ui.narrow {
		ui.buddies.selected = 0
	}
}

// open_conversation shows the inbox with the DM with `account`, on the
// shown server.
open_conversation :: proc(ui: ^UI, account: proto.Account_Id) {
	ui.page = .Buddies
	if ui.buddies.selected != account {
		ui.buddies.len = 0
	}
	ui.buddies.selected = account
}

// open_entry opens the DM with someone in the inbox: straight away on
// the shown server, or once their server is shown (see switch_now).
@(private = "file")
open_entry :: proc(ui: ^UI, e: Buddy_Entry) {
	if e.ns == ui.session {
		open_conversation(ui, e.account)
		return
	}
	ui.switch_to, ui.switching = e.ns, true
	ui.inbox_open = e.account
}

// keep_viewing makes the network side look at `conv` (with `back`, the
// channel it was looking at before the DM), if it isn't already. It asks once,
// and asks again only if that has no effect. Call with the View locked.
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
		ui_redraw_at(ui, time.tick_add(b.view_at, VIEW_RETRY)) // so that it asks again
		return
	}
	b.view_asked, b.view_back, b.view_at = want, back, time.tick_now()
	ui_redraw_in(ui, VIEW_RETRY)
	conn.push_command(&ui.session.client.commands, conn.View_Command{conv = conv, back = back})
}

// back_from_dms is the session screen making sure that what it shows is a
// channel's: after coming back from the buddy screen, or after having been sent
// there by something else. Call with the View locked.
back_from_dms :: proc(ui: ^UI) {
	v := ui.view
	if v.viewing == 0 && v.channel == 0 {
		return // none reported yet
	}
	if v.viewing == 0 || viewed_channel(v) == nil {
		keep_viewing(ui, 0, back = true)
	}
}

// buddies_screen lays the screen out, like session_screen: side by
// side or, in a narrow window, with the list and the picked conversation
// taking turns, and the conversation having a way back to the list. Call with
// the View locked.
buddies_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	body := mu.get_current_container(ctx).body
	narrow := body.w < NARROW_LAYOUT
	ui.narrow = narrow

	// Watching somebody's screen (from a call's row in the voice panel)
	// works here as beside a channel: with a Screen tab, and fullscreen. So
	// does a call's video, in the Video tab.
	screen_tab_follow(ui)
	camera_tab_follow(ui)
	if camera_fullscreen(ui) {
		camera_full_screen(ui)
		return
	}
	if ui.view.watching != 0 && conn.video_is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	session_header(ui)

	list := ui.inbox
	// Somebody who has left the list (removed from it, or no longer a buddy
	// and with no DM) takes the conversation along.
	entry: Buddy_Entry
	found := false
	for e in list {
		if e.ns == ui.session && e.account == ui.buddies.selected {
			entry, found = e, true
		}
	}
	if !found && ui.buddies.selected != 0 {
		if ui.buddies.selected in ui.view.accounts && ui.buddies.selected != ui.view.me {
			// Picked from somewhere else (a channel's member list).
			entry, found = buddy_entry(ui.view, ui.buddies.selected, false), true
			entry.ns = ui.session
		} else {
			ui.buddies.selected = 0
		}
	}
	keep_viewing(ui, entry.conv if found else 0)

	// The list over the voice panel, beside the conversation. In a narrow
	// window, either the list over the panel or the conversation over it.
	panel_h := voice_panel_height(ui)
	switch {
	case narrow && !found:
		mu.layout_row(ctx, {-1}, -(panel_h + 1))
		buddy_list_panel(ui, list)
		voice_panel(ui)
	case narrow:
		mu.layout_row(ctx, {-1}, -(panel_h + 1))
		conversation_or_screen(ui, entry, found, narrow)
		voice_panel(ui)
	case:
		mu.layout_row(ctx, {280, -1}, -1)
		mu.layout_begin_column(ctx)
		mu.layout_row(ctx, {-1}, -(panel_h + 1))
		buddy_list_panel(ui, list)
		voice_panel(ui)
		mu.layout_end_column(ctx)
		conversation_or_screen(ui, entry, found, narrow)
	}
	user_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
	share_menu(ui)
}

// conversation_or_screen shows the conversation or, while we are watching
// somebody's screen or are in a call with a camera on, the conversation, the
// screen and the call's video as tabs, like a channel's chat (see side_panel in
// ui_chat.odin). With `narrow`, the line at the top starts with the way back to
// the list.
@(private = "file")
conversation_or_screen :: proc(ui: ^UI, entry: Buddy_Entry, found: bool, narrow: bool) {
	if !side_tabs_shown(ui) {
		conversation(ui, entry, found, narrow)
		return
	}
	ctx := &ui.ctx
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)

	mu.layout_row(ctx, side_tab_widths(ui, 40 if narrow else 0))
	if narrow {
		back_to_list(ui)
	}
	side_tab_buttons(ui, "Chat")
	mu.label(ctx, "")
	#partial switch ui.chat.tab {
	case .Screen:
		screen_panel(ui)
	case .Video:
		video_panel(ui)
	case:
		mu.layout_row(ctx, {-1}, -1)
		conversation(ui, entry, found, false)
	}
}

// back_to_list is the narrow window's way from a conversation back to
// the list, in which no conversation is picked then.
@(private = "file")
back_to_list :: proc(ui: ^UI) {
	if .SUBMIT in icon_button(ui, "to inbox list", .Back, "Conversations") {
		ui.buddies.selected = 0
	}
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
			theme.dim,
			"You have no buddies yet. Click someone in the channel list and add them from the menu.",
			text_proc,
		)
		return
	}
	// The buddies first, then everyone else (see buddy_before).
	others := len(list)
	for b, i in list {
		if !b.buddy {
			others = i
			break
		}
	}
	section_label(ui, "Buddies")
	if others == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "None yet. Add someone from their menu.", label_proc)
	}
	for b in list[:others] {
		buddy_row(ui, b)
	}
	if others < len(list) {
		section_label(ui, "Other conversations")
		for b in list[others:] {
			buddy_row(ui, b)
		}
	}
}

// section_label is the heading of one of the list's sections.
@(private = "file")
section_label :: proc(ui: ^UI, text: string) {
	mu.layout_row(&ui.ctx, {-1})
	with_text_color(&ui.ctx, theme.dim, text, label_proc)
}

// buddy_row is one buddy in the list: a flat, full-width control like the
// channel list's rows, ending in the tag of their server when there is more
// than one. A left click opens their conversation, and a right click (on the
// shown server) opens the same menu as clicking them in a channel.
@(private = "file")
buddy_row :: proc(ui: ^UI, b: Buddy_Entry) {
	ctx := &ui.ctx
	here := b.ns == ui.session
	servers := rail_count(ui) > 1

	pic := ctx.text_height(ctx.style.font) + 2
	mu.layout_row(ctx, {pic + 4, -1})
	cell := mu.layout_next(ctx)
	pic_r := mu.Rect{cell.x, cell.y + (cell.h - pic) / 2, pic, pic}
	if here {
		avatar(ui, b.account, pic_r)
	} else {
		// Pictures are known by the shown server's blob ids.
		letter_disc(ui, b.account, b.name, pic_r)
	}

	mu.push_id(ctx, uintptr(rawptr(b.ns)))
	defer mu.pop_id(ctx)
	mu.push_id(ctx, uintptr(b.account))
	defer mu.pop_id(ctx)
	id := mu.get_id(ctx, "buddy")
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	selected := here && ui.buddies.selected == b.account
	switch {
	case selected:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_FOCUS])
	case ctx.hover_id == id:
		mu.draw_rect(ctx, r, ctx.style.colors[.BUTTON_HOVER])
	}
	text_r := r
	if servers {
		text_r.w -= server_tag(ui, r, b.server, b.ns.server)
	}
	color := ctx.style.colors[.TEXT] if b.online else theme.dim
	text := b.name
	if b.unread > 0 {
		text = fmt.tprintf("%s  (%s)", b.name, conn.unread_count(b.unread))
		color = theme.speaking
	}
	icon_r := name_and_status(
		ctx,
		text_r,
		text,
		color,
		b.status,
		bold = selected,
		talking = b.talking,
	)

	if ctx.hover_id != id {
		return
	}
	if servers {
		ui.hint, ui.hint_of = fmt.tprintf("On %s", b.server), r
	}
	talking_hint(ui, icon_r, b.talking)
	switch {
	case ctx.mouse_pressed_bits == {.LEFT}:
		open_entry(ui, b)
	case .RIGHT in ctx.mouse_pressed_bits && here:
		open_user_menu(ui, 0, b.account)
	}
}

// conversation is the right-hand side: who it is with, the messages,
// and the box to write in. With `back`, the line with their name starts
// with the way back to the list (see back_to_list).
@(private = "file")
conversation :: proc(ui: ^UI, entry: Buddy_Entry, found: bool, back: bool) {
	ctx := &ui.ctx
	v := ui.view

	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	drop_zone(ui)

	if !found {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "Pick a buddy to start talking.", label_proc)
		return
	}
	account := entry.account

	// Their name, and the button that removes a DM from the list (for somebody
	// who isn't a buddy, where there is something to remove).
	can_hide := entry.conv != 0 && !entry.buddy
	// The name, then its buttons: up to five (a video call beside the call
	// where we can send our camera).
	video := camera_available(v)
	icons := 1 if entry.conv == 0 else 4 if can_hide else 3
	if video {
		icons += 1
	}
	buf: [6]i32
	widths := buf[:icons + 1]
	widths[0] = -(icon_button_w(ctx) * i32(icons) + ctx.style.spacing * i32(icons + 1))
	for &w in widths[1:] {
		w = icon_button_w(ctx)
	}
	if back {
		row := make([]i32, len(widths) + 1, context.temp_allocator)
		row[0] = 40
		copy(row[1:], widths)
		mu.layout_row(ctx, row)
		back_to_list(ui)
	} else {
		mu.layout_row(ctx, widths)
	}
	deleted := .Deleted in (v.accounts[account] or_else {}).flags
	title := entry.name if entry.buddy || deleted else fmt.tprintf("%s  (not a buddy)", entry.name)
	if rail_count(ui) > 1 {
		// Which of the inbox's servers it is on.
		title = fmt.tprintf(
			"%s  ·  %s",
			title,
			v.server_name if v.server_name != "" else v.server,
		)
	}
	mu.label(ctx, title)
	// Calling them, while they are online and we are in no call.
	if !deleted && may_call(v, account) {
		if .SUBMIT in icon_button(ui, "dm call", .Phone, "Call") {
			call_account(ui, account)
		}
		if video && .SUBMIT in icon_button(ui, "dm video call", .Camera, "Video call") {
			call_account(ui, account, video = true)
		}
	} else {
		mu.label(ctx, "")
		if video {
			mu.label(ctx, "")
		}
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
			   "Remove this conversation from the list until something new is said in it",
			   theme.off,
		   ) {
		last: proto.Msg_Id
		for dm in v.dms {
			if dm.id == entry.conv {
				last = dm.last
			}
		}
		settings.hide_dm(&ui.settings, v.server_key, entry.conv, max(last, 1))
		shared_hidden_changed(ui.session, entry.conv, max(last, 1))
		ui.settings_dirty = true
		ui.buddies.selected = 0
		log.debug("ui: hid a conversation")
		return
	}
	mu.layout_row(ctx, {-1})
	if deleted {
		// What is there can be read, but nothing more can be said (the server
		// refuses it too).
		with_text_color(
			ctx,
			theme.dim,
			"Their account was deleted. You can still read this conversation, but not write to it.",
			label_proc,
		)
		mu.layout_row(ctx, {-1}, -1)
		if entry.conv != 0 && v.viewing == entry.conv {
			timeline(ui, &ui.timeline, {entry.conv, 0}, readonly = true)
		}
		return
	}
	status := "here now" if entry.online else last_seen_text(ui, account)
	status_color := theme.speaking if entry.online else theme.dim
	if entry.conv != 0 && conn.is_typing(v, account, entry.conv) {
		status = "typing..."
	} else if entry.conv != 0 && conn.is_typing_in_thread(v, account, entry.conv) {
		status = "typing in a thread..."
	}
	if ui.paste != nil {
		status = "reading the clipboard..."
	}
	if editing := composer_status(composer_of_page(ui)); editing != "" {
		status, status_color = editing, theme.dim
	}
	if notice, ok, fresh := fresh_notice(v); fresh && !ok {
		status, status_color = notice, theme.off
	}
	if ui.buddies.notice != "" && time.tick_since(ui.buddies.notice_at) < NOTICE_SHOW {
		status, status_color = ui.buddies.notice, theme.off
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
	composer_row(ui, input_h)
	completion_keys(ui, composer)
	composer_keys(ui, composer)
	res, box, box_rect := composer_box(ui, composer)
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
	composer_buttons(ui, box_rect, 5)
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
	if composer_send_button(
		ui,
		composer,
		"dm send",
		"Save" if ui.buddies.editing != 0 else "Enter: Send\nCtrl+Enter: New line",
	) {
		send = true
	}
	composer_buttons_end(ui)
	if !send {
		return
	}
	// Enter takes the focus away from the box, so keep typing instead.
	mu.set_focus(ctx, box)
	composer_send(ui, composer, account)
}

// no_conversation_yet stands in for the timeline where there is no DM
// yet (or it is on its way): what we have written to them, going out.
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
	if entry.conv != 0 {
		spinner_row(ui) // its messages, on their way
		return
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, fmt.tprintf("Nothing said with %s yet.", entry.name), label_proc)
}

// ask_last_seen asks a server when those in its part of the inbox who
// aren't online were last seen: when the inbox opens, every LAST_SEEN_REFRESH,
// and as soon as someone in it leaves. Each server is asked about its own
// accounts. Call with its View locked.
ask_last_seen :: proc(ui: ^UI, ns: ^Net_Session, list: []Buddy_Entry) {
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
	someone_left := online < ns.seen_online
	ns.seen_online = online
	due := ns.seen_asked == {} || time.tick_since(ns.seen_asked) >= LAST_SEEN_REFRESH
	if cmd.count == 0 || !(due || someone_left) {
		if cmd.count != 0 {
			ui_redraw_at(ui, time.tick_add(ns.seen_asked, LAST_SEEN_REFRESH))
		}
		return
	}
	ns.seen_asked = time.tick_now()
	ui_redraw_in(ui, LAST_SEEN_REFRESH)
	conn.push_command(&ns.client.commands, cmd)
}

// last_seen_text is what the conversation's header says about someone
// who isn't online: how long ago they were last seen, as far as the server says.
last_seen_text :: proc(ui: ^UI, account: proto.Account_Id) -> string {
	seen, known := ui.view.last_seen[account]
	if !known || seen == proto.LAST_SEEN_HIDDEN || seen == 0 {
		// The server only tells people who have written to each other.
		return ""
	}
	return fmt.tprintf("last seen %s", ago_text(ui, i64(seen)))
}

// ago_text is how long ago a time (in Unix milliseconds) was: "just now",
// "3 hours ago", or its date once it is more than a week ago.
ago_text :: proc(ui: ^UI, ms: i64) -> string {
	ago := (time.time_to_unix_nano(time.now()) / 1_000_000 - ms) / 1000
	plural :: proc(n: i64) -> string {
		return "" if n == 1 else "s"
	}
	switch {
	case ago < 60:
		return "just now"
	case ago < 60 * 60:
		return fmt.tprintf("%d minute%s ago", ago / 60, plural(ago / 60))
	case ago < 24 * 60 * 60:
		return fmt.tprintf("%d hour%s ago", ago / 3600, plural(ago / 3600))
	case ago < 7 * 24 * 60 * 60:
		return fmt.tprintf("%d day%s ago", ago / 86400, plural(ago / 86400))
	}
	return chat_time(ui, proto.Unix_Time(ms / 1000))
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}
