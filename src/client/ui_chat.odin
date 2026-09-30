package client

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:unicode/utf8"
import mu "vendor:microui"

import "common:proto"
import "client:platform"
import "client:conn"

/*
The right-hand side of the session screen: the channel's text chat and
the log, as tabs.
*/

Side_Tab :: enum {
	Chat,
	Log,
	Screen, // while watching somebody's (ui_video.odin)
}

UI_Chat :: struct {
	tab:      Side_Tab,
	buf:      [proto.MAX_CHAT_SIZE]u8,
	len:      int,
	scrolled: int, // chat_total + outbox length when last scrolled to the bottom
	tz:       ^datetime.TZ_Region, // for local timestamps; nil means UTC

	// The link under the mouse (as its first byte's address), found while
	// drawing a frame and used for the next, since a link wrapped over
	// several lines is drawn in pieces. 0 if none.
	hover:    uintptr,
	hovering: bool, // this frame; the cursor becomes a hand
	open:     string, // clicked link to open after the frame; owned
	// Ctrl+V was pressed in the chat box: after the frame, the paste
	// thread looks for an image on the clipboard, else its text is
	// pasted (see ui_paste.odin).
	paste:    bool,
}

CHAT_NAME_COLOR :: mu.Color{120, 170, 230, 255}
CHAT_OWN_COLOR :: mu.Color{140, 200, 140, 255}
CHAT_DIM_COLOR :: mu.Color{140, 140, 140, 255}
LINK_COLOR :: mu.Color{100, 165, 245, 255}
LINK_HOVER_COLOR :: mu.Color{160, 205, 255, 255}

ui_chat_init :: proc(ui: ^UI) {
	chat_load_timezone(ui)
}

ui_chat_destroy :: proc(ui: ^UI) {
	chat_unload_timezone(ui)
	delete(ui.chat.open)
}

// ui_chat_after_frame acts on what the frame's layout found: the mouse
// cursor over links, and a clicked link (opened outside the View lock).
ui_chat_after_frame :: proc(ui: ^UI) {
	if !ui.chat.hovering {
		ui.chat.hover = 0
	}
	ui.chat.hovering = false
	if ui.chat.open != "" {
		platform.open_url(ui.chat.open)
		delete(ui.chat.open)
		ui.chat.open = ""
	}
	if ui.chat.paste {
		ui.chat.paste = false
		paste_start(ui)
	}
	if ui.buddies.pick {
		ui.buddies.pick = false
		file_pick_start(ui, ui.buddies.pick_to)
	}
	paste_poll(ui)
	file_pick_poll(ui)
}

// side_panel lays out the tabs in the current layout cell. Call with the
// View locked.
side_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)

	if ui.chat.tab == .Chat {
		v.chat_unread = 0
	}
	if v.watching != 0 {
		mu.layout_row(ctx, {90, 90, 90, -1})
	} else {
		mu.layout_row(ctx, {90, 90, -1})
	}
	chat_label := "Chat" if v.chat_unread == 0 else fmt.tprintf("Chat (%d)", v.chat_unread)
	if .SUBMIT in tab_button(ctx, "chat tab", chat_label, ui.chat.tab == .Chat) {
		ui.chat.tab = .Chat
		ui.chat.scrolled = -1 // back to the newest messages
	}
	if .SUBMIT in tab_button(ctx, "log tab", "Log", ui.chat.tab == .Log) {
		ui.chat.tab = .Log
		ui.log_seen = -1
	}
	if v.watching != 0 &&
	   .SUBMIT in tab_button(ctx, "screen tab", "Screen", ui.chat.tab == .Screen) {
		ui.chat.tab = .Screen
	}
	status := "reading the clipboard..." if ui.paste != nil else typing_text(v)
	with_text_color(ctx, CHAT_DIM_COLOR, status, label_proc)

	switch ui.chat.tab {
	case .Chat:
		// Leave room for the input row below.
		input_h := ctx.style.size.y + 2 * ctx.style.padding
		mu.layout_row(ctx, {-1}, -(input_h + ctx.style.spacing + 1))
		chat_panel(ui)
		chat_input(ui)
	case .Log:
		mu.layout_row(ctx, {-1}, -1)
		log_panel(ui)
	case .Screen:
		screen_panel(ui)
	}
}

// tab_button is a stable_button drawn pressed while its tab is shown.
@(private = "file")
tab_button :: proc(ctx: ^mu.Context, id_name, label: string, active: bool) -> mu.Result_Set {
	if !active {
		return stable_button(ctx, id_name, label)
	}
	saved := ctx.style.colors[.BUTTON]
	ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
	defer ctx.style.colors[.BUTTON] = saved
	return stable_button(ctx, id_name, label)
}

@(private = "file")
chat_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view

	mu.begin_panel(ctx, "chat")
	cnt := mu.get_current_container(ctx)
	select_begin(ui, .Chat)
	// Each message is two items to select from, its header and its text,
	// numbered by the running total so they keep their numbers as lines
	// come and go (see ui_select.odin).
	first := i64(v.chat_total - len(v.chat))
	if len(v.chat) == 0 && len(v.outbox) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, CHAT_DIM_COLOR, "No messages in this channel yet.", label_proc)
	}
	for line, i in v.chat {
		// Same sender, same minute as the line right before it: read as
		// one block, so only the first of them needs a header, and the
		// gap between them is tighter (see chat_message).
		merged :=
			i > 0 &&
			line.sender == v.chat[i - 1].sender &&
			chat_same_minute(line.time, v.chat[i - 1].time)
		header := "" if merged else fmt.tprintf("%s  %s", chat_time(ui, line.time), line.name)
		header_color := CHAT_OWN_COLOR if line.sender == v.my_num else CHAT_NAME_COLOR
		switch line.kind {
		case .Text:
			chat_message(
				ui,
				header,
				header_color,
				line.text,
				ctx.style.colors[.TEXT],
				links = true,
				merged = merged,
				item = (first + i64(i)) * 2,
			)
		case .Image:
			img := v.images[line.image.id] or_else {}
			chat_image(
				ui,
				header,
				header_color,
				line.image,
				img,
				merged = merged,
				item = (first + i64(i)) * 2,
			)
		}
	}
	for text, i in v.outbox {
		chat_message(
			ui,
			"sending...",
			CHAT_DIM_COLOR,
			text,
			CHAT_DIM_COLOR,
			links = false,
			merged = false,
			item = (i64(v.chat_total) + i64(i)) * 2,
		)
	}
	select_end(ui)
	mu.end_panel(ctx)

	// Follow new messages, unless that would pull the text out from
	// under a selection being dragged.
	dragging := ui.select.dragging && ui.select.panel == .Chat
	if seen := v.chat_total + len(v.outbox); seen != ui.chat.scrolled && !dragging {
		ui.chat.scrolled = seen
		cnt.scroll.y = cnt.content_size.y
	}
}

@(private = "file")
chat_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(ICON_BUTTON + 6), ICON_BUTTON})
	// Ctrl+V could be an image: hold the text paste back and decide after
	// the frame (see paste). The id is the one text_box uses.
	// A browser hands the picture over from its paste event instead (see
	// web/paste.js), so the key is left to the text box there.
	if !platform.WEB &&
	   ctx.focus_id == mu.get_id(ctx, uintptr(&ui.chat.buf[0])) &&
	   .V in ctx.key_pressed_bits &&
	   .CTRL in ctx.key_down_bits &&
	   .ALT not_in ctx.key_down_bits {
		ctx.key_pressed_bits -= {.V}
		ui.chat.paste = true
		ui.paste_to = {}
	}
	res := text_box(ui, ui.chat.buf[:], &ui.chat.len)
	box := ctx.last_id
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil {
		conn.push_command(&ui.session.client.commands, conn.Typing_Command{})
	}
	send := .SUBMIT in res
	if .SUBMIT in icon_button(ui, "send", .Send, "Send") {
		send = true
	}
	if !send {
		return
	}
	// Enter takes the focus away from the box; keep typing instead.
	mu.set_focus(ctx, box)
	text := strings.trim_space(string(ui.chat.buf[:ui.chat.len]))
	if text == "" || ui.session == nil {
		return
	}
	log.debug("ui: chat message")
	conn.push_command(&ui.session.client.commands, conn.Chat_Command{strings.clone(text)})
	ui.chat.len = 0
}

// typing_text says who in our channel is typing, or "".
@(private = "file")
typing_text :: proc(v: ^conn.View) -> string {
	if v.my_channel < 0 || v.my_channel >= len(v.channels) {
		return ""
	}
	names := make([dynamic]string, context.temp_allocator)
	for m in v.channels[v.my_channel].members {
		if m != v.my_num && conn.is_typing(v, m) {
			u, ok := v.users[m]
			append(&names, u.name if ok else "someone")
		}
	}
	switch len(names) {
	case 0:
		return ""
	case 1:
		return fmt.tprintf("%s is typing...", names[0])
	case 2:
		return fmt.tprintf("%s and %s are typing...", names[0], names[1])
	case:
		return fmt.tprintf("%d people are typing...", len(names))
	}
}

// chat_time formats a message's time in the local zone: the time of day
// for today's messages, with the date for older ones. The buddy screen
// uses it too, for when someone was last here.
chat_time :: proc(ui: ^UI, unix: proto.Unix_Time) -> string {
	local :: proc(ui: ^UI, t: time.Time) -> datetime.DateTime {
		dt, _ := time.time_to_datetime(t)
		return chat_local_time(ui, dt)
	}
	dt := local(ui, time.unix(i64(unix), 0))
	now := local(ui, time.now())
	if dt.date == now.date {
		return fmt.tprintf("%02d:%02d", dt.hour, dt.minute)
	}
	return fmt.tprintf("%d-%02d-%02d %02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute)
}

// chat_same_minute says whether two messages read as part of the same
// block: close enough in time that showing both their headers would
// just repeat the same sender and (usually) the same minute.
@(private = "file")
chat_same_minute :: proc(a, b: proto.Unix_Time) -> bool {
	return a / 60 == b / 60
}

// How much closer together a merged message sits, against the usual gap
// between two separate ones (ctx.style.spacing).
@(private = "file")
MERGED_GAP :: 1

// chat_image draws an image message: the gap before it, the header
// (unless `merged`, in which case it's part of the previous message's
// block and sits right under it instead), then the picture.
@(private = "file")
chat_image :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	info: proto.Image_Info,
	img: conn.View_Image,
	merged: bool,
	item: i64,
	gone := "image no longer on the server",
) {
	ctx := &ui.ctx
	font := ctx.style.font
	// 1, not 0: a height of 0 tells layout_row to fall back to the
	// default control size, which (plus the parent's own row spacing)
	// would set a floor under how short this block can be - taller than
	// a merged one-liner is supposed to end up.
	mu.layout_row(ctx, {-1}, 1)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	saved := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged else saved)
	mu.layout_next(ctx) // the gap

	if !merged {
		mu.layout_row(ctx, {-1}, ctx.text_height(font))
		selectable_header(ui, header, header_color, item)
	}
	// An image the server has dropped has no id left to look it up by.
	state := img.state if info.id != 0 else conn.Image_State.Gone
	image_block(ui, info, state, img.jpeg, gone)
}

/*
dm_panel shows a conversation's messages, as the chat panel does the
channel's: a header over each block of messages from one side within a
minute, saying for ours how far they've got. Call with the View locked.
*/
dm_panel :: proc(ui: ^UI, conv: ^conn.View_Conversation, their_name: string) {
	ctx := &ui.ctx
	v := &ui.view

	mu.begin_panel(ctx, "conversation")
	cnt := mu.get_current_container(ctx)
	select_begin(ui, .DM)
	if len(conv.messages) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, CHAT_DIM_COLOR, "No messages yet.", label_proc)
	}
	me := v.my_name if v.my_name != "" else "me"
	for m, i in conv.messages {
		prev := conv.messages[i - 1] if i > 0 else conn.View_DM{}
		merged :=
			i > 0 &&
			m.mine == prev.mine &&
			m.state == prev.state &&
			chat_same_minute(m.time, prev.time)
		status := ""
		color := ctx.style.colors[.TEXT]
		header_color := CHAT_OWN_COLOR if m.mine else CHAT_NAME_COLOR
		switch m.state {
		case .Received, .Delivered:
		case .Sending:
			status, color = "  sending...", CHAT_DIM_COLOR
		case .Sent:
			status = "  sent"
		case .Failed:
			status, header_color = "  not sent", OFF_COLOR
		}
		header := fmt.tprintf(
			"%s  %s%s",
			chat_time(ui, m.time),
			me if m.mine else their_name,
			status,
		)
		// Each message is up to four items to select from (a file's
		// header, name and state), numbered by where it is.
		item := i64(i) * 4
		if m.is_file {
			f :=
				v.dm_files[m.id] or_else conn.View_File {
					name = m.text,
					state = .Expired,
					outgoing = m.mine,
				}
			file_message(ui, header, header_color, m.id, f, merged, item)
			continue
		}
		if m.is_image {
			img := v.dm_images[m.image.id] or_else conn.View_Image{info = m.image, state = .Gone}
			chat_image(
				ui,
				header,
				header_color,
				m.image,
				img,
				merged = merged,
				item = item,
				gone = "image no longer available",
			)
			continue
		}
		chat_message(
			ui,
			header,
			header_color,
			m.text,
			color,
			links = true,
			merged = merged,
			item = item,
		)
	}
	select_end(ui)
	mu.end_panel(ctx)

	// Follow new messages, unless a selection is being dragged.
	dragging := ui.select.dragging && ui.select.panel == .DM
	if conv.changes != ui.buddies.scrolled && !dragging {
		ui.buddies.scrolled = conv.changes
		cnt.scroll.y = cnt.content_size.y
	}
}

/*
file_message draws a file offer in a conversation: the header, the file's
name and size, how it's going (with a bar while it's under way), and the
buttons that fit: Accept and Decline for one offered to us, Cancel while
it isn't over.
*/
@(private = "file")
file_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	id: u64,
	f: conn.View_File,
	merged: bool,
	item: i64,
) {
	ctx := &ui.ctx
	font := ctx.style.font
	// 1, not 0: see the same line in chat_image.
	mu.layout_row(ctx, {-1}, 1)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	saved := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged else saved)
	mu.layout_next(ctx) // the gap
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	if !merged {
		selectable_header(ui, header, header_color, item)
	}
	wrapped_text(
		ui,
		fmt.tprintf("File: %s  (%s)", f.name, conn.format_bytes(f.size)),
		ctx.style.colors[.TEXT],
		nil,
		item + 1,
	)

	status, color := file_status(f)
	if f.state == .Transferring {
		// The bar, below the name.
		mu.layout_row(ctx, {-1}, 3)
		mu.layout_next(ctx)
		mu.layout_row(ctx, {-1}, 6)
		r := mu.layout_next(ctx)
		r.w = min(r.w, 300)
		mu.draw_rect(ctx, r, {60, 60, 60, 255})
		done := f32(f.done) / f32(max(f.size, 1))
		mu.draw_rect(ctx, {r.x, r.y, i32(f32(r.w) * clamp(done, 0, 1)), r.h}, SPEAKING_COLOR)
		mu.layout_row(ctx, {-1}, 2)
		mu.layout_next(ctx)
	}
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	wrapped_text(ui, status, color, nil, item + 2)

	// The buttons, spaced like the rest of the UI.
	send :: proc(ui: ^UI, id: u64, action: conn.File_Action) {
		if ui.session != nil {
			conn.push_command(
				&ui.session.client.commands,
				conn.File_Action_Command{id = id, action = action},
			)
		}
	}
	ctx.style.spacing = saved
	mu.push_id(ctx, uintptr(id))
	defer mu.pop_id(ctx)
	switch f.state {
	case .Incoming:
		mu.layout_row(ctx, {90, 90})
		if .SUBMIT in stable_button(ctx, "accept", "Accept") {
			send(ui, id, .Accept)
		}
		if .SUBMIT in stable_button(ctx, "decline", "Decline") {
			send(ui, id, .Decline)
		}
	case .Offered, .Starting, .Transferring:
		mu.layout_row(ctx, {90})
		if .SUBMIT in stable_button(ctx, "cancel", "Cancel") {
			send(ui, id, .Cancel)
		}
	case .Done, .Declined, .Cancelled, .Failed, .Interrupted, .Expired:
	}
}

// file_status says how a transfer is going, and in what colour.
@(private = "file")
file_status :: proc(f: conn.View_File) -> (string, mu.Color) {
	switch f.state {
	case .Offered:
		return "waiting for them to accept", CHAT_DIM_COLOR
	case .Incoming:
		return "wants to send you this", CHAT_NAME_COLOR
	case .Starting:
		return "starting...", CHAT_DIM_COLOR
	case .Transferring:
		percent := 100 * f64(f.done) / f64(max(f.size, 1))
		text := fmt.tprintf(
			"%.0f%%  -  %s of %s",
			percent,
			conn.format_bytes(f.done),
			conn.format_bytes(f.size),
		)
		if f.rate > 0 {
			text = fmt.tprintf("%s  -  %s/s", text, conn.format_bytes(u64(f.rate)))
		}
		return text, CHAT_DIM_COLOR
	case .Done:
		if f.outgoing {
			return "sent", SPEAKING_COLOR
		}
		when platform.WEB {
			return "downloaded", SPEAKING_COLOR
		} else {
			return fmt.tprintf("saved to %s", f.path), SPEAKING_COLOR
		}
	case .Declined:
		return "declined" if !f.outgoing else "they declined", CHAT_DIM_COLOR
	case .Cancelled:
		return "cancelled", CHAT_DIM_COLOR
	case .Failed:
		return "failed", OFF_COLOR
	case .Interrupted:
		return "stopped: one side left", OFF_COLOR
	case .Expired:
		return "no longer available", CHAT_DIM_COLOR
	}
	return "", CHAT_DIM_COLOR
}

// chat_message draws the gap before this message, a header line unless
// `merged` (see chat_image), and the wrapped text under it, with the
// lines packed tightly.
@(private = "file")
chat_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	text: string,
	color: mu.Color,
	links: bool,
	merged: bool,
	item: i64, // the header's; the text is the next one
) {
	ctx := &ui.ctx
	font := ctx.style.font
	// 1, not 0: see the same line in chat_image.
	mu.layout_row(ctx, {-1}, 1)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	saved := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged else saved)
	mu.layout_next(ctx) // the gap

	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	if !merged {
		selectable_header(ui, header, header_color, item)
	}
	wrapped_text(ui, text, color, platform.find_links(text) if links else nil, item + 1)
}

// selectable_header draws a message's header line in the next layout
// cell.
@(private = "file")
selectable_header :: proc(ui: ^UI, header: string, color: mu.Color, item: i64) {
	ctx := &ui.ctx
	r := mu.layout_next(ctx)
	select_item(ui, item, header)
	select_line(ui, item, header, 0, len(header), {r.x, r.y})
	mu.draw_text(ctx, ctx.style.font, header, {r.x, r.y}, color)
}

// wrapped_text is mu.text, except it also breaks words too long for a
// line, wraps the last word of a paragraph (which mu.text doesn't), and
// draws `links` (byte ranges of `text`) as clickable links. It continues
// the current row layout. The text can be selected as `item`.
@(private = "file")
wrapped_text :: proc(ui: ^UI, text: string, color: mu.Color, links: []platform.Link, item: i64) {
	ctx := &ui.ctx
	font := ctx.style.font
	select_item(ui, item, text)
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end := line_end(ctx, font, rest, r.w)
		start := len(text) - len(rest)
		select_line(ui, item, text, start, start + end, {r.x, r.y})
		draw_line(ui, text, start, start + end, {r.x, r.y}, color, links)
		rest = strings.trim_left_space(rest[end:])
	}
}

// draw_line draws text[start:end], in pieces where it overlaps links.
@(private = "file")
draw_line :: proc(
	ui: ^UI,
	text: string,
	start, end: int,
	pos: mu.Vec2,
	color: mu.Color,
	links: []platform.Link,
) {
	ctx := &ui.ctx
	font := ctx.style.font
	x := pos.x
	piece :: proc(
		ctx: ^mu.Context,
		font: mu.Font,
		s: string,
		x: ^i32,
		y: i32,
		color: mu.Color,
	) -> mu.Rect {
		w := ctx.text_width(font, s)
		mu.draw_text(ctx, font, s, {x^, y}, color)
		r := mu.Rect{x^, y, w, ctx.text_height(font)}
		x^ += w
		return r
	}

	at := start
	for l in links {
		if l.end <= at || l.start >= end {
			continue
		}
		if l.start > at {
			piece(ctx, font, text[at:l.start], &x, pos.y, color)
			at = l.start
		}
		link_end := min(l.end, end)
		id := uintptr(raw_data(text)) + uintptr(l.start)
		hovered := ui.chat.hover == id
		r := piece(
			ctx,
			font,
			text[at:link_end],
			&x,
			pos.y,
			LINK_HOVER_COLOR if hovered else LINK_COLOR,
		)
		// Underline, just below the baseline.
		mu.draw_rect(
			ctx,
			{r.x, r.y + r.h - 2, r.w, 1},
			LINK_HOVER_COLOR if hovered else LINK_COLOR,
		)
		if mu.mouse_over(ctx, r) {
			ui.chat.hover = id
			ui.chat.hovering = true
			// On the release of a press in this panel, and only if that
			// didn't end a drag that selected something (ui_select.odin).
			if .LEFT in ctx.mouse_released_bits &&
			   ui.select.dragging &&
			   ui.select.panel == ui.select.drawing &&
			   !has_selection(&ui.select, ui.select.drawing) &&
			   ui.chat.open == "" {
				ui.chat.open = platform.link_url(text, l, context.allocator)
			}
		}
		at = link_end
	}
	if at < end {
		piece(ctx, font, text[at:end], &x, pos.y, color)
	}
}

// line_end is how much of `text` fits in `width`: up to the last space
// that fits, or as many characters as fit if the first word doesn't
// (but always at least one character).
@(private = "file")
line_end :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> int {
	last_space := -1
	fit := 0
	w: i32
	for ch, i in text {
		size := utf8.rune_size(ch)
		w += ctx.text_width(font, text[i:][:size])
		if w > width && fit > 0 {
			return last_space if last_space > 0 else fit
		}
		fit = i + size
		if ch == ' ' {
			last_space = i
		}
	}
	return len(text)
}
