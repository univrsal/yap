package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:time/datetime"
import "core:unicode/utf8"
import mu "vendor:microui"

import "common:proto"
import "client:platform"
import "client:conn"
import "client:render"
import glfw "client:wglfw"

/*
The right-hand side of the session screen: the channel's text chat, or
the log (opened from the header, ui.odin), or while watching somebody's
screen, that and the chat as tabs.
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
	// The message of ours being edited in the chat box, 0 for none, and
	// its conversation (ui_message_menu.odin).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
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
	timeline_destroy(&ui.timeline)
	ui_threads_destroy(ui)
	ui_message_menu_destroy(ui)
	ui_completion_destroy(ui)
	ui_forward_destroy(ui)
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
	links_after_frame(ui)
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
	avatar_pick_poll(ui)

	// What's read, and what's unread: for the network, the window's title
	// and the tray.
	focused := ui.window != nil && !ui.hidden && (ALWAYS_FOCUSED || glfw.WindowFocused(ui.window))
	timeline_reading(ui, focused)
	{
		sync.guard(&ui.view.mutex)
		ui.unread = unread_total(&ui.settings, &ui.view) if ui.session != nil else 0
	}
	if ui.window != nil && ui.unread != ui.title_unread {
		ui.title_unread = ui.unread
		title := "Yap" if ui.unread == 0 else fmt.tprintf("(%s) Yap", conn.unread_count(ui.unread))
		glfw.SetWindowTitle(ui.window, strings.clone_to_cstring(title, context.temp_allocator))
	}
}

// side_panel lays out the channel's header and the tabs in the current
// layout cell. Call with the View locked.
side_panel :: proc(ui: ^UI, narrow: bool) {
	ctx := &ui.ctx
	v := &ui.view

	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)

	conversation_header(ui, narrow)

	if ui.chat.tab == .Chat {
		v.unread = 0
	}
	// Tabs only while there's a screen to watch beside the chat; the
	// status line has the row to itself otherwise.
	if v.watching != 0 {
		mu.layout_row(ctx, {90, 90, -1})
		chat_label := "Chat" if v.unread == 0 else fmt.tprintf("Chat (%d)", v.unread)
		if .SUBMIT in tab_button(ctx, "chat tab", chat_label, ui.chat.tab == .Chat) {
			ui.chat.tab = .Chat
		}
		if .SUBMIT in tab_button(ctx, "screen tab", "Screen", ui.chat.tab == .Screen) {
			ui.chat.tab = .Screen
		}
	} else {
		mu.layout_row(ctx, {-1})
	}
	status := "reading the clipboard..." if ui.paste != nil else typing_text(v)
	status_color := CHAT_DIM_COLOR
	if editing := composer_status(composer_of_page(ui)); editing != "" {
		status = editing
	}
	if notice, ok, fresh := fresh_notice(v); fresh {
		status, status_color = notice, CHAT_DIM_COLOR if ok else ERROR_COLOR
	}
	when TIMELINE_DEBUG {
		status = fmt.tprintf("%s  [%d laid out, %d off]", status, ui.timeline.laid_out, ui.timeline.mismatched)
	}
	with_text_color(ctx, status_color, status, label_proc)

	switch ui.chat.tab {
	case .Chat:
		// In a narrow window an open thread takes the conversation's
		// place (ui_threads.odin).
		if narrow {
			if slot := narrow_thread(ui); slot != 0 {
				thread_panel(ui, slot, true)
				break
			}
		}
		// Leave room for the input row below.
		input_h := composer_height(ui)
		mu.layout_row(ctx, {-1}, -(input_h + ctx.style.spacing + 1))
		timeline(ui, &ui.timeline, {v.viewing, 0})
		chat_input(ui)
	case .Log:
		mu.layout_row(ctx, {-1}, -1)
		log_panel(ui)
	case .Screen:
		screen_panel(ui)
	}
}

// composer_height is how tall a box we write messages in is: a
// control's height, or more for the chat's text when it's bigger
// (settings.chat_scale).
composer_height :: proc(ui: ^UI) -> i32 {
	ctx := &ui.ctx
	return max(ctx.style.size.y + 2 * ctx.style.padding, ctx.text_height(render.CHAT_FONT) + 4)
}

// chat_text_box is text_box in the chat's font: the box we write
// messages in.
chat_text_box :: proc(ui: ^UI, buf: []u8, textlen: ^int) -> mu.Result_Set {
	ctx := &ui.ctx
	saved := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved
	return text_box(ui, buf, textlen)
}

// tab_button is a stable_button drawn pressed while its tab is shown.
tab_button :: proc(ctx: ^mu.Context, id_name, label: string, active: bool) -> mu.Result_Set {
	if !active {
		return stable_button(ctx, id_name, label)
	}
	// Lighter, and its label in the colour of a header button that's
	// open, so which tab is shown reads at a glance.
	saved, saved_text := ctx.style.colors[.BUTTON], ctx.style.colors[.TEXT]
	ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
	ctx.style.colors[.TEXT] = CHAT_NAME_COLOR
	defer ctx.style.colors[.BUTTON], ctx.style.colors[.TEXT] = saved, saved_text
	return stable_button(ctx, id_name, label)
}

@(private = "file")
chat_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(2 * ICON_BUTTON + 10), ICON_BUTTON, ICON_BUTTON}, composer_height(ui))
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
	composer := Composer{ui.chat.buf[:], &ui.chat.len, &ui.chat.editing, &ui.chat.editing_conv, 0}
	completion_keys(ui, composer)
	composer_keys(ui, composer)
	res := chat_text_box(ui, ui.chat.buf[:], &ui.chat.len)
	box := ctx.last_id
	if takes_focus(ui, composer) {
		focus_at(ctx, box, ui.chat.len if ui.focus_composer_at < 0 else ui.focus_composer_at)
	}
	completion_update(ui, composer)
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil && ui.chat.editing == 0 {
		conn.push_command(&ui.session.client.commands, conn.Typing_Command{})
	}
	send := .SUBMIT in res
	emoji_button(ui, composer)
	if .SUBMIT in icon_button(ui, "send", .Send, "Save" if ui.chat.editing != 0 else "Send") {
		send = true
	}
	if !send {
		return
	}
	// Enter takes the focus away from the box; keep typing instead.
	mu.set_focus(ctx, box)
	composer_send(ui, composer)
}

// How long a notice (conn.notify) shows in the line over a conversation.
@(private = "file")
NOTICE_SHOW :: 5 * time.Second

// fresh_notice is the notice the network side gave last, if it was
// lately. Call with the View locked.
fresh_notice :: proc(v: ^conn.View) -> (text: string, ok: bool, fresh: bool) {
	if v.notice.text == "" || v.notice.at == {} || time.tick_since(v.notice.at) > NOTICE_SHOW {
		return
	}
	return v.notice.text, v.notice.ok, true
}

// typing_text says who is typing in the conversation we're looking at
// (or with `root`, in that thread of it), or "". For the conversation,
// with nobody typing in it, it says who is typing in its threads.
typing_text :: proc(v: ^conn.View, root: proto.Msg_Id = 0) -> string {
	names := make([dynamic]string, context.temp_allocator)
	in_threads := false
	for pass in 0 ..< 2 {
		for account in v.typing {
			typing :=
				conn.is_typing(v, account, v.viewing, root) if pass == 0 else conn.is_typing_in_thread(v, account, v.viewing)
			if account != v.me && typing {
				acc, ok := v.accounts[account]
				append(&names, acc.display if ok else "someone")
			}
		}
		if len(names) > 0 || root != 0 {
			break
		}
		in_threads = true
	}
	place := " in a thread" if in_threads else ""
	switch len(names) {
	case 0:
		return ""
	case 1:
		return fmt.tprintf("%s is typing%s...", names[0], place)
	case 2:
		return fmt.tprintf("%s and %s are typing%s...", names[0], names[1], place)
	case:
		return fmt.tprintf("%d people are typing%s...", len(names), place)
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
chat_same_minute :: proc(a, b: proto.Unix_Time) -> bool {
	return a / 60 == b / 60
}

// How much closer together a merged message sits, against the usual gap
// between two separate ones (ctx.style.spacing).
MERGED_GAP :: 1

// chat_image draws a picture message: the gap before it, the header
// (unless `merged`, in which case it's part of the previous message's
// block and sits right under it instead), then the picture, which is
// `key` to image_block. `tight` is a header with the gap of a merged
// one: under a reply's line.
chat_image :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	key: u64,
	info: proto.Msg_Image,
	img: conn.View_Image,
	merged: bool,
	item: i64,
	gone := "image no longer on the server",
	available := 0, // how wide the picture may be; 0 for the panel's width
	tight := false,
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

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged || tight else saved)
	mu.layout_next(ctx) // the gap

	if !merged {
		mu.layout_row(ctx, {-1}, ctx.text_height(font))
		selectable_header(ui, header, header_color, item)
	}
	image_block(ui, key, info, img.state, img.jpeg, gone, available)
}

// chat_block_height is how far chat_message or chat_image moves the
// layout down, `body` being the height of what's under the header (the
// text's lines, or the picture). The timeline works out where messages
// are with it, without laying them out; it has to agree with those two.
chat_block_height :: proc(ctx: ^mu.Context, merged: bool, body: i32, tight := false) -> i32 {
	line := ctx.text_height(ctx.style.font)
	h := (MERGED_GAP if merged || tight else ctx.style.spacing) + (0 if merged else line) + body
	// The one-pixel row the block's column starts on, and its spacing.
	return max(h, 1 + ctx.style.spacing)
}

// wrapped_lines is how many lines wrapped_text breaks `text` into at
// `width`.
wrapped_lines :: proc(ctx: ^mu.Context, text: string, width: i32) -> (n: i32) {
	font := ctx.style.font
	rest := text
	for len(rest) > 0 {
		end := line_end(ctx, font, rest, width)
		rest = strings.trim_left_space(rest[end:])
		n += 1
	}
	return
}

/*
file_message draws a file offer in a conversation: the header, the file's
name and size, how it's going (with a bar while it's under way, and room
for one otherwise), and the buttons that fit: Accept and Decline for one
offered to us, Cancel while it isn't over. file_block_height has to agree
with it.
*/
file_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	id: proto.Msg_Id,
	f: conn.View_File,
	merged: bool,
	item: i64, // the header's; the file's name and state are the next two
	tight := false, // as in chat_image
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

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged || tight else saved)
	mu.layout_next(ctx) // the gap
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	if !merged {
		selectable_header(ui, header, header_color, item)
	}
	wrapped_text(ui, file_title(f), ctx.style.colors[.TEXT], nil, item + 1)

	// The bar, below the name, while it's under way; its room either way.
	mu.layout_row(ctx, {-1}, FILE_BAR_GAP)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {-1}, FILE_BAR)
	r := mu.layout_next(ctx)
	if f.state == .Transferring {
		r.w = min(r.w, 300)
		mu.draw_rect(ctx, r, {60, 60, 60, 255})
		done := f32(f.done) / f32(max(f.size, 1))
		mu.draw_rect(ctx, {r.x, r.y, i32(f32(r.w) * clamp(done, 0, 1)), r.h}, SPEAKING_COLOR)
	}
	mu.layout_row(ctx, {-1}, FILE_BAR_GAP)
	mu.layout_next(ctx)
	status, color := file_status(f)
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	wrapped_text(ui, status, color, nil, item + 2)

	// The buttons, spaced like the rest of the UI.
	send :: proc(ui: ^UI, id: proto.Msg_Id, action: conn.File_Action) {
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
	case .Unknown,
	     .Posting,
	     .Done,
	     .Declined,
	     .Cancelled,
	     .Failed,
	     .Interrupted,
	     .Expired,
	     .Elsewhere:
	}
}

// The room under a file's name for the bar, and around it.
@(private = "file")
FILE_BAR :: 6
@(private = "file")
FILE_BAR_GAP :: 2

@(private = "file")
file_title :: proc(f: conn.View_File) -> string {
	return fmt.tprintf("File: %s  (%s)", f.name, conn.format_bytes(f.size))
}

@(private = "file")
file_has_buttons :: proc(f: conn.View_File) -> bool {
	#partial switch f.state {
	case .Incoming, .Offered, .Starting, .Transferring:
		return true
	}
	return false
}

// file_block_height is how far file_message moves the layout down at
// `width`.
file_block_height :: proc(ui: ^UI, f: conn.View_File, width: i32, merged: bool, tight := false) -> i32 {
	ctx := &ui.ctx
	line := ctx.text_height(ctx.style.font)
	status, _ := file_status(f)
	body :=
		wrapped_lines(ctx, file_title(f), width) * line +
		2 * FILE_BAR_GAP +
		FILE_BAR +
		wrapped_lines(ctx, status, width) * line
	if file_has_buttons(f) {
		body += ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
	}
	return chat_block_height(ctx, merged, body, tight)
}

// file_status says how a transfer is going, and in what colour.
@(private = "file")
file_status :: proc(f: conn.View_File) -> (string, mu.Color) {
	switch f.state {
	case .Unknown:
		return "offered earlier, or on another device" if !f.outgoing else "offered from another device", CHAT_DIM_COLOR
	case .Posting:
		return "offering...", CHAT_DIM_COLOR
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
	case .Elsewhere:
		return "answered on another of your devices", CHAT_DIM_COLOR
	}
	return "", CHAT_DIM_COLOR
}

// chat_message draws the gap before this message, a header line unless
// `merged` (see chat_image), and the wrapped text under it, with the
// lines packed tightly.
chat_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	text: string,
	color: mu.Color,
	links: bool,
	merged: bool,
	item: i64, // the header's; the text is the next one
	mentions: []conn.Mention_Span = nil, // in `text`, as text_display has them
	emoji: []conn.Emoji_Span = nil, // the same
	tight := false, // as in chat_image
	msg_links: []conn.Link_Span = nil, // links to messages, the same
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

	mu.layout_row(ctx, {-1}, MERGED_GAP if merged || tight else saved)
	mu.layout_next(ctx) // the gap

	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	if !merged {
		selectable_header(ui, header, header_color, item)
	}
	// Web links and links to messages, in order, the first where they'd
	// overlap (a message's words may have an address in them).
	all: []platform.Link
	if links {
		all = platform.find_links(text)
	}
	if len(msg_links) > 0 {
		merged := make([dynamic]platform.Link, context.temp_allocator)
		for ml in msg_links {
			append(&merged, platform.Link{ml.start, ml.end})
		}
		outer: for l in all {
			for ml in msg_links {
				if l.start < ml.end && ml.start < l.end {
					continue outer
				}
			}
			append(&merged, l)
		}
		slice.sort_by(merged[:], proc(a, b: platform.Link) -> bool {return a.start < b.start})
		all = merged[:]
	}
	wrapped_text(ui, text, color, all, item + 1, mentions, emoji, msg_links)
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
// draws `links` (byte ranges of `text`) as clickable links and `mentions`
// highlighted. It continues the current row layout. The text can be
// selected as `item`.
@(private = "file")
wrapped_text :: proc(
	ui: ^UI,
	text: string,
	color: mu.Color,
	links: []platform.Link,
	item: i64,
	mentions: []conn.Mention_Span = nil,
	emoji: []conn.Emoji_Span = nil,
	msg_links: []conn.Link_Span = nil,
) {
	ctx := &ui.ctx
	font := ctx.style.font
	select_item(ui, item, text)
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end := line_end(ctx, font, rest, r.w)
		start := len(text) - len(rest)
		select_line(ui, item, text, start, start + end, {r.x, r.y})
		draw_line(ui, text, start, start + end, {r.x, r.y}, color, links, mentions, msg_links)
		draw_emoji(ui, text, start, start + end, {r.x, r.y}, emoji)
		emoji_hint(ui, text, start, start + end, {r.x, r.y, r.w, ctx.text_height(font)}, emoji)
		rest = strings.trim_left_space(rest[end:])
	}
}

// draw_line draws text[start:end], in pieces where it overlaps links and
// mentions.
@(private = "file")
draw_line :: proc(
	ui: ^UI,
	text: string,
	start, end: int,
	pos: mu.Vec2,
	color: mu.Color,
	links: []platform.Link,
	mentions: []conn.Mention_Span,
	msg_links: []conn.Link_Span = nil,
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
			mention_pieces(ctx, text, at, l.start, &x, pos.y, color, mentions)
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
				// A link to a message is gone to; anything else is a
				// web address.
				to_message := false
				for ml in msg_links {
					if ml.start == l.start {
						ui.forward.go_conv, ui.forward.go_id = ml.link.conv, ml.link.id
						to_message = true
					}
				}
				if !to_message {
					ui.chat.open = platform.link_url(text, l, context.allocator)
				}
			}
		}
		at = link_end
	}
	if at < end {
		mention_pieces(ctx, text, at, end, &x, pos.y, color, mentions)
	}
}

/*
emoji_hint names the emoji under the pointer, if it's over one in
text[start:end], drawn in `line`: `:name:`, one of the font's (by its
first shortcode) or one of the server's (a placeholder character, with a
span saying which).
*/
@(private = "file")
emoji_hint :: proc(ui: ^UI, text: string, start, end: int, line: mu.Rect, emoji: []conn.Emoji_Span) {
	ctx := &ui.ctx
	if !mu.mouse_over(ctx, line) {
		return
	}
	font := ctx.style.font
	mouse := ctx.mouse_pos.x
	x := line.x
	for i := start; i < end; {
		r, size := utf8.decode_rune_in_string(text[i:end])
		w := ctx.text_width(font, text[i:i + size])
		if mouse >= x && mouse < x + w {
			name := ""
			for e in emoji {
				if e.start == i && e.index < len(ui.view.emoji.names) {
					name = ui.view.emoji.names[e.index]
				}
			}
			if name == "" {
				if index, ok := proto.emoji_index(r); ok {
					name = proto.emoji_name(proto.EMOJI[index])
				}
			}
			if name != "" {
				ui.hint, ui.hint_of = fmt.tprintf(":%s:", name), {x, line.y, w, line.h}
			}
			return
		}
		x += w
		i += size
	}
}

// custom_emoji_size is how big one of the server's emoji is drawn and
// how much room it has, in the current font: bigger in the chat when
// its text is (render.CHAT_FONT).
custom_emoji_size :: proc(ctx: ^mu.Context) -> (size, advance: i32) {
	zoom := f32(ctx.text_height(ctx.style.font)) / render.LINE_HEIGHT
	return i32(render.CUSTOM_EMOJI_SIZE * zoom), i32(render.CUSTOM_EMOJI_ADVANCE * zoom)
}

// draw_emoji draws the server's emoji over their placeholders in
// text[start:end], drawn at `pos`.
@(private = "file")
draw_emoji :: proc(ui: ^UI, text: string, start, end: int, pos: mu.Vec2, emoji: []conn.Emoji_Span) {
	ctx := &ui.ctx
	font := ctx.style.font
	for e in emoji {
		if e.start < start || e.start >= end {
			continue
		}
		icon, ok := custom_emoji_icon(ui, e.index)
		if !ok {
			continue
		}
		x := pos.x + ctx.text_width(font, text[start:e.start])
		size, advance := custom_emoji_size(ctx)
		gap := (advance - size) / 2
		y := pos.y + (ctx.text_height(font) - size) / 2
		mu.draw_icon(ctx, icon, {x + gap, y, size, size}, {255, 255, 255, 255})
	}
}

// How a mention is drawn: in its own colour, and on a background when it's
// the reader's.
MENTION_COLOR :: mu.Color{235, 185, 95, 255}
MENTION_ME_BACKGROUND :: mu.Color{110, 80, 25, 255}

// mention_pieces draws text[start:end] from x along, in pieces where it
// overlaps mentions, and moves x on past it.
@(private = "file")
mention_pieces :: proc(
	ctx: ^mu.Context,
	text: string,
	start, end: int,
	x: ^i32,
	y: i32,
	color: mu.Color,
	mentions: []conn.Mention_Span,
) {
	font := ctx.style.font
	draw :: proc(ctx: ^mu.Context, font: mu.Font, s: string, x: ^i32, y: i32, color: mu.Color, background: mu.Color) {
		w := ctx.text_width(font, s)
		if background.a > 0 {
			mu.draw_rect(ctx, {x^ - 1, y, w + 2, ctx.text_height(font)}, background)
		}
		mu.draw_text(ctx, font, s, {x^, y}, color)
		x^ += w
	}
	at := start
	for m in mentions {
		if m.end <= at || m.start >= end {
			continue
		}
		if m.start > at {
			draw(ctx, font, text[at:m.start], x, y, color, {})
			at = m.start
		}
		upto := min(m.end, end)
		draw(ctx, font, text[at:upto], x, y, MENTION_COLOR, MENTION_ME_BACKGROUND if m.me else {})
		at = upto
	}
	if at < end {
		draw(ctx, font, text[at:end], x, y, color, {})
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
