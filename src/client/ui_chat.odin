package client

import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:unicode"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import glfw "client:wglfw"
import "common:proto"

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
	tab:          Side_Tab,
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it's written in

	// The link under the mouse (as its first byte's address), found while
	// drawing a frame and used for the next, since a link wrapped over
	// several lines is drawn in pieces. 0 if none.
	hover:        uintptr,
	hovering:     bool, // this frame; the cursor becomes a hand
	open:         string, // clicked link to open after the frame; owned
	// Ctrl+V was pressed in the chat box: after the frame, the paste
	// thread looks for an image on the clipboard, else its text is
	// pasted (see ui_paste.odin).
	paste:        bool,
	// The message of ours being edited in the chat box, 0 for none, and
	// its conversation (ui_message_menu.odin).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	// Files to go with the next message (ui_attachments.odin).
	files:        [dynamic]Picked_File,
}

CHAT_NAME_COLOR :: mu.Color{120, 170, 230, 255}
CHAT_OWN_COLOR :: mu.Color{140, 200, 140, 255}
CHAT_DIM_COLOR :: mu.Color{140, 140, 140, 255}
LINK_COLOR :: mu.Color{100, 165, 245, 255}
LINK_HOVER_COLOR :: mu.Color{160, 205, 255, 255}

ui_chat_init :: proc(ui: ^UI) {
	chat_load_timezone(ui)
}

// ui_chat_destroy frees what the chat keeps that isn't one server's;
// that is server_ui_destroy's (ui_servers.odin).
ui_chat_destroy :: proc(ui: ^UI) {
	chat_unload_timezone(ui)
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
	if ui.attach_pick {
		ui.attach_pick = false
		attach_pick_start(ui, ui.attach_to)
	}
	if len(ui.dropped) > 0 {
		attach_dropped(ui)
	}
	paste_poll(ui)
	file_pick_poll(ui)
	avatar_pick_poll(ui)

	// What's read, for the network; what's unread, every server's, is
	// counted for the window's title and the tray (servers_frame).
	focused := ui.window != nil && !ui.hidden && (ALWAYS_FOCUSED || glfw.WindowFocused(ui.window))
	timeline_reading(ui, focused)
}

// side_panel lays out the channel's header and the tabs in the current
// layout cell. Call with the View locked.
side_panel :: proc(ui: ^UI, narrow: bool) {
	ctx := &ui.ctx
	v := ui.view

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
		status = fmt.tprintf(
			"%s  [%d laid out, %d off]",
			status,
			ui.timeline.laid_out,
			ui.timeline.mismatched,
		)
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
		// Leave room for the input row below, and the files above it.
		input_h := composer_height(ui, composer_of(ui, 0))
		width := panel_width(ctx)
		files_h := composer_files_height(ui, composer_of(ui, 0), width)
		mu.layout_row(ctx, {-1}, -(input_h + files_h + ctx.style.spacing + 1))
		timeline(ui, &ui.timeline, {v.viewing, 0})
		composer_files(ui, composer_of(ui, 0), width)
		chat_input(ui)
	case .Log:
		mu.layout_row(ctx, {-1}, -1)
		log_panel(ui)
	case .Screen:
		screen_panel(ui)
	}
}

// panel_width is how wide the rows of the panel being laid out are.
panel_width :: proc(ctx: ^mu.Context) -> i32 {
	return mu.get_current_container(ctx).body.w - 2 * ctx.style.padding
}

// composer_height is how tall the box a composer's message is written in
// is: a line or more of the chat's text (ui_text_area.odin).
composer_height :: proc(ui: ^UI, c: Composer) -> i32 {
	return text_area_height(&ui.ctx, render.CHAT_FONT, string(c.buf[:c.len^]), c.area)
}

/*
composer_row lays out the row a composer's box is in, `height` tall,
with `buttons` icon buttons beside it: the box, then a column for the
buttons, which stay a line's height at the foot of the box however tall
it grows. Lay the box out, then the buttons, then end the column with
mu.layout_end_column.
*/
composer_row :: proc(ui: ^UI, height: i32, buttons: int) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(i32(buttons) * (ICON_BUTTON + 4) + 2), -1}, height)
}

// composer_buttons starts the column of a composer_row's buttons, after
// its box.
composer_buttons :: proc(ui: ^UI, height: i32, buttons: int) {
	ctx := &ui.ctx
	mu.layout_begin_column(ctx)
	single := text_area_single(ctx, render.CHAT_FONT)
	if height > single {
		mu.layout_row(ctx, {-1}, height - single - ctx.style.spacing)
		mu.layout_next(ctx)
	}
	widths: [8]i32
	for &w in widths[:buttons] {
		w = ICON_BUTTON
	}
	mu.layout_row(ctx, widths[:buttons], single)
}

/*
composer_box lays out the box a composer's message is written in: its
text area, or with the preview on (preview_button), the message as it
will look. It has the composer take the focus when it's to (which ends
the preview), and says what the text area did and the box's id.
*/
composer_box :: proc(ui: ^UI, c: Composer) -> (res: mu.Result_Set, box: mu.Id) {
	ctx := &ui.ctx
	box = mu.get_id(ctx, uintptr(&c.buf[0]))
	if c.area.preview {
		chat_preview(ui, c)
	} else {
		res = chat_text_area(ui, c)
	}
	if takes_focus(ui, c) {
		c.area.preview = false
		focus_at(ctx, box, c.len^ if ui.focus_composer_at < 0 else ui.focus_composer_at)
		ui_redraw(ui) // for the box to show it has the focus, and the caret
	}
	return
}

// preview_button is the eye beside a composer's box, which shows the
// message as it will look in its place, and back (D8).
preview_button :: proc(ui: ^UI, c: Composer) {
	if .SUBMIT in
	   icon_button(ui, "preview", .Eye, "Back to writing" if c.area.preview else "Preview") {
		c.area.preview = !c.area.preview
		if !c.area.preview {
			focus_composer(ui, c, -1)
		}
	}
}

/*
chat_preview shows what's in a composer as it will look sent, in its
box's place: what's typed made into what's stored (mentions, emoji), and
shown as the timeline shows it, in a panel that scrolls. Call with the
View locked.
*/
@(private = "file")
chat_preview :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
	v := ui.view
	saved := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved
	typed := strings.trim_space(string(c.buf[:c.len^]))
	color := ctx.style.colors[.TEXT]
	text: Rich
	if typed == "" {
		text, color = rich_plain("Nothing to preview yet."), CHAT_DIM_COLOR
	} else {
		text = message_rich(
			ui,
			conn.emoji_encode(
				conn.mentions_encode(typed, v.accounts, v.roles[:]),
				v.emoji.names[:],
			),
		)
	}
	mu.begin_panel(ctx, fmt.tprintf("composer preview %d", c.thread))
	defer mu.end_panel(ctx)
	spacing := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = spacing
	mu.layout_row(ctx, {-1}, ctx.text_height(ctx.style.font))
	rich_text(ui, &text, color, 0)
}

// chat_text_area is text_area in the chat's font: the box a composer's
// message is written in.
chat_text_area :: proc(ui: ^UI, c: Composer) -> mu.Result_Set {
	ctx := &ui.ctx
	saved := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved
	return text_area(ui, c.buf, c.len, c.area)
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
	composer := composer_of(ui, 0)
	input_h := composer_height(ui, composer)
	composer_row(ui, input_h, 4)
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
	completion_keys(ui, composer)
	composer_keys(ui, composer)
	res, box := composer_box(ui, composer)
	completion_update(ui, composer)
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil && ui.chat.editing == 0 {
		conn.push_command(&ui.session.client.commands, conn.Typing_Command{})
	}
	send := .SUBMIT in res
	composer_buttons(ui, input_h, 4)
	attach_button(ui, composer)
	emoji_button(ui, composer)
	preview_button(ui, composer)
	if .SUBMIT in icon_button(ui, "send", .Send, "Save" if ui.chat.editing != 0 else "Send") {
		send = true
	}
	mu.layout_end_column(ctx)
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

// notice_until is when the notice the network side gave last comes
// down; zero if it isn't up. Call with the View locked.
notice_until :: proc(v: ^conn.View) -> time.Tick {
	if _, _, fresh := fresh_notice(v); !fresh {
		return {}
	}
	return time.tick_add(v.notice.at, NOTICE_SHOW)
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
		rest = next_line(rest, end)
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
	wrapped_text(ui, file_title(f), ctx.style.colors[.TEXT], item + 1)

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
	wrapped_text(ui, status, color, item + 2)

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
file_block_height :: proc(
	ui: ^UI,
	f: conn.View_File,
	width: i32,
	merged: bool,
	tight := false,
) -> i32 {
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
		return "offered earlier, or on another device" if !f.outgoing else "offered from another device",
			CHAT_DIM_COLOR
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
// `merged` (see chat_image), and the text under it (ui_rich_text.odin),
// with the lines packed tightly.
chat_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	text: ^Rich,
	color: mu.Color,
	merged: bool,
	item: i64, // the header's; the text is the next one
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
	rich_text(ui, text, color, item + 1)
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
	if ui.header_sender != 0 {
		font := ctx.style.font
		lo, hi := ui.header_name[0], ui.header_name[1]
		x := r.x + ctx.text_width(font, header[:lo])
		hit := mu.Rect{x, r.y, ctx.text_width(font, header[lo:hi]), r.h}
		if mu.mouse_over(ctx, hit) {
			ui.chat.hovering = true // a hand, as over a link
			if clicked_not_dragged(ui) {
				open_user_menu(ui, 0, ui.header_sender)
			}
		}
	}
}

// clicked_not_dragged is whether the left button was released in this
// panel's text without a press that selected something, as for a link
// (ui_rich_text.odin).
clicked_not_dragged :: proc(ui: ^UI) -> bool {
	return(
		.LEFT in ui.ctx.mouse_released_bits &&
		ui.select.dragging &&
		ui.select.panel == ui.select.drawing &&
		!has_selection(&ui.select, ui.select.drawing) \
	)
}

// wrapped_text is mu.text, except it also breaks words too long for a
// line, wraps the last word of a paragraph (which mu.text doesn't) and
// breaks lines at newlines. It continues the current row layout. The
// text can be selected as `item`. For plain text (a file's name); a
// message's is rich_text.
@(private = "file")
wrapped_text :: proc(ui: ^UI, text: string, color: mu.Color, item: i64) {
	ctx := &ui.ctx
	font := ctx.style.font
	select_item(ui, item, text)
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end := line_end(ctx, font, rest, r.w)
		start := len(text) - len(rest)
		select_line(ui, item, text, start, start + end, {r.x, r.y})
		mu.draw_text(ctx, font, text[start:start + end], {r.x, r.y}, color)
		rest = next_line(rest, end)
	}
}

// custom_emoji_size is how big one of the server's emoji is drawn and
// how much room it has, in the current font: bigger in the chat when
// its text is (render.CHAT_FONT).
custom_emoji_size :: proc(ctx: ^mu.Context) -> (size, advance: i32) {
	zoom := f32(ctx.text_height(ctx.style.font)) / render.LINE_HEIGHT
	return i32(render.CUSTOM_EMOJI_SIZE * zoom), i32(render.CUSTOM_EMOJI_ADVANCE * zoom)
}

// How a mention is drawn: in its own colour, and on a background when it's
// the reader's.
MENTION_COLOR :: mu.Color{235, 185, 95, 255}
MENTION_ME_BACKGROUND :: mu.Color{110, 80, 25, 255}

// wrap_line is the first line of `text` wrapped at `width`, as the chat
// wraps it: text[:end] is drawn, and the next line starts at `next`
// (past the newline or the spaces it broke at).
wrap_line :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> (end, next: int) {
	end = line_end(ctx, font, text, width)
	return end, len(text) - len(next_line(text, end))
}

// line_end is how much of `text` fits in `width`: up to the first
// newline if that fits, else up to the last space that fits, or as many
// characters as fit if the first word doesn't (but always at least one
// character, unless the line is empty).
@(private = "file")
line_end :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> int {
	last_space := -1
	fit := 0
	w: i32
	for ch, i in text {
		if ch == '\n' {
			return i
		}
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

// next_line is what's left of `text` after a line of it that ended at
// `end` (line_end): past the newline that ended it, or past the spaces it
// was wrapped at (and a newline right after them, which the wrap has
// already broken the line for). The next line's indentation stays.
@(private = "file")
next_line :: proc(text: string, end: int) -> string {
	rest := text[end:]
	if strings.has_prefix(rest, "\n") {
		return rest[1:]
	}
	rest = strings.trim_left_proc(
		rest,
		proc(r: rune) -> bool {return r != '\n' && unicode.is_space(r)},
	)
	return strings.trim_prefix(rest, "\n")
}
