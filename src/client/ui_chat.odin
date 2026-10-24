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

// The right-hand side of the session screen: the channel's text chat, or
// the log (opened from the header, see ui.odin) or, while watching somebody's
// screen or in a call with a camera on, the chat, that screen and the call's
// video as tabs.

Side_Tab :: enum {
	Chat,
	Log,
	Screen, // while watching somebody's screen (see ui_video.odin)
	Video, // in a call while a camera is on (see ui_camera.odin)
}

UI_Chat :: struct {
	tab:          Side_Tab,
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it is written in

	// The link under the mouse (as its first byte's address), found while
	// drawing a frame and used for the next one, because a link that wraps over
	// several lines is drawn in pieces. 0 if none.
	hover:        uintptr,
	hovering:     bool, // set in this frame; the cursor becomes a hand
	open:         string, // the clicked link to open after the frame; owned
	// Ctrl+V was pressed in a composer (see ui.paste_to). After the frame,
	// the paste thread looks for an image on the clipboard to attach. If there is
	// none, the clipboard's text is pasted instead (see ui_paste.odin).
	paste:        bool,
	// The message of ours that is being edited in the chat box (0 for none),
	// and its conversation (see ui_message_menu.odin).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	// Files to go with the next message (see ui_attachments.odin).
	files:        [dynamic]Picked_File,
}

ui_chat_init :: proc(ui: ^UI) {
	chat_load_timezone(ui)
	ui.date_style = date_style_of(platform.locale_name())
}

// ui_chat_destroy frees what the chat keeps that doesn't belong to one server.
// What does belong to a server is freed by server_ui_destroy (see ui_servers.odin).
ui_chat_destroy :: proc(ui: ^UI) {
	chat_unload_timezone(ui)
}

// ui_chat_after_frame acts on what the frame's layout found: the mouse
// cursor over links, and a clicked link (which is opened outside the View lock).
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

	// What is read, for the network. What is unread, across all servers, is
	// counted for the window's title and the tray (see servers_frame).
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
	drop_zone(ui)
	conversation_header(ui, narrow)

	if ui.chat.tab == .Chat {
		v.unread = 0
	}
	// Tabs only while there is a screen or a call's video beside the chat.
	// What is going on (chat_status) is in the header's line.
	if side_tabs_shown(ui) {
		mu.layout_row(ctx, side_tab_widths(ui))
		chat_label := "Chat" if v.unread == 0 else fmt.tprintf("Chat (%d)", v.unread)
		side_tab_buttons(ui, chat_label)
	}

	switch ui.chat.tab {
	case .Chat:
		// In a narrow window an open thread takes the conversation's
		// place (see ui_threads.odin).
		if narrow {
			if slot := narrow_thread(ui); slot != 0 {
				thread_panel(ui, slot, true)
				break
			}
		}
		// Where we may not write, a line saying so takes the composer's place.
		if .Write not_in rights_here(v) {
			mu.layout_row(ctx, {-1}, -(read_only_height(ctx) + ctx.style.spacing + 1))
			timeline(ui, &ui.timeline, {v.viewing, 0})
			read_only_line(ui)
			break
		}
		// Leave room for the input row below, and for the files above it.
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
	case .Video:
		video_panel(ui)
	}
}

// read_only_height is how tall read_only_line is.
read_only_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding
}

// read_only_line is what is shown instead of a composer in a channel we may
// not write in.
read_only_line :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, read_only_height(ctx))
	with_text_color(ctx, theme.dim, "You can't write in this channel.", label_proc)
}

// side_tabs_shown says whether the chat has tabs beside it: while there is a
// screen to watch (screen_docked) or a call's video (video_docked). Call with
// the View locked.
side_tabs_shown :: proc(ui: ^UI) -> bool {
	return screen_docked(ui) || video_docked(ui)
}

// side_tab_widths is a row for side_tab_buttons: `lead` before the tabs (0 for
// nothing), a tab each, and the rest of the row (-1) for whatever follows.
// Allocated in the temp allocator. Call with the View locked.
side_tab_widths :: proc(ui: ^UI, lead: i32 = 0) -> []i32 {
	TAB :: 90
	widths := make([dynamic]i32, context.temp_allocator)
	if lead > 0 {
		append(&widths, lead)
	}
	append(&widths, TAB)
	if screen_docked(ui) {
		append(&widths, TAB)
	}
	if video_docked(ui) {
		append(&widths, TAB)
	}
	append(&widths, -1)
	return widths[:]
}

// side_tab_buttons draws the tabs: the chat, and the screen and the call's video
// while they are offered. Call with the View locked.
side_tab_buttons :: proc(ui: ^UI, chat_label: string) {
	ctx := &ui.ctx
	chat_shown := ui.chat.tab != .Screen && ui.chat.tab != .Video
	if .SUBMIT in tab_button(ctx, "chat tab", chat_label, chat_shown) {
		ui.chat.tab = .Chat
	}
	if screen_docked(ui) &&
	   .SUBMIT in tab_button(ctx, "screen tab", "Screen", ui.chat.tab == .Screen) {
		ui.chat.tab = .Screen
	}
	if video_docked(ui) &&
	   .SUBMIT in tab_button(ctx, "video tab", video_tab_label(ui), ui.chat.tab == .Video) {
		ui.chat.tab = .Video
	}
}

// panel_width is how wide the rows of the panel being laid out are.
panel_width :: proc(ctx: ^mu.Context) -> i32 {
	return mu.get_current_container(ctx).body.w - 2 * ctx.style.padding
}

// A composer's box is at least this many lines of the chat's text tall, with
// a strip along its bottom for its buttons (composer_buttons): square buttons
// of COMPOSER_BUTTON (composer_button_size), COMPOSER_INSET in from the box's
// edges.
COMPOSER_LINES :: 2
COMPOSER_BUTTON :: 26
COMPOSER_INSET :: 4

// composer_button_size is how big a composer's buttons are: COMPOSER_BUTTON,
// or a control's height where that is more (a fingertip, on a phone).
composer_button_size :: proc(ctx: ^mu.Context) -> i32 {
	return max(COMPOSER_BUTTON, ctx.style.size.y + 2 * ctx.style.padding)
}

// composer_height is how tall the box that a composer's message is written in
// is: two lines or more of the chat's text (see ui_text_area.odin), and the
// strip for its buttons.
composer_height :: proc(ui: ^UI, c: Composer) -> i32 {
	// On a phone, one line to start with, to leave room for the messages.
	c.area.min_lines = 1 if ui.compact else COMPOSER_LINES
	c.area.footer = composer_button_size(&ui.ctx) + COMPOSER_INSET
	return text_area_height(&ui.ctx, render.CHAT_FONT, string(c.buf[:c.len^]), c.area)
}

// composer_row lays out the row that a composer's box is in, `height` tall.
// Lay out the box (composer_box), then its buttons (composer_buttons, the
// buttons, and composer_buttons_end).
composer_row :: proc(ui: ^UI, height: i32) {
	mu.layout_row(&ui.ctx, {-1}, height)
}

// composer_buttons lays out a row of `buttons` icon buttons at the bottom right
// of a composer's box `box` (from composer_box), over the strip that the box
// keeps free of text. They are drawn flat, without a frame, except for the
// send button (composer_send_button). End them with composer_buttons_end.
composer_buttons :: proc(ui: ^UI, box: mu.Rect, buttons: int) {
	ctx := &ui.ctx
	size := composer_button_size(ctx)
	w := i32(buttons) * size + i32(buttons - 1) * ctx.style.spacing
	strip := mu.Rect {
		box.x + box.w - COMPOSER_INSET - w,
		box.y + box.h - COMPOSER_INSET - size,
		w,
		size,
	}
	mu.layout_set_next(ctx, strip, false)
	mu.layout_begin_column(ctx)
	widths: [8]i32
	for &bw in widths[:buttons] {
		bw = size
	}
	mu.layout_row(ctx, widths[:buttons], size)
	ui.flat_buttons = true
}

composer_buttons_end :: proc(ui: ^UI) {
	ui.flat_buttons = false
	mu.layout_end_column(&ui.ctx)
}

// composer_send_button is a composer's send button, the last of its buttons:
// grey while there is nothing to send, and in the accent color once there is.
// It returns whether it was pressed.
composer_send_button :: proc(ui: ^UI, c: Composer, id_name, hint: string) -> bool {
	ctx := &ui.ctx
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	pressed := ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id
	ready :=
		strings.trim_space(string(c.buf[:c.len^])) != "" || (c.files != nil && len(c.files) > 0)
	over := ctx.hover_id == id
	back, fore: mu.Color
	if ready {
		back, fore = theme.accent_hover if over else theme.accent, theme.accent_text
	} else {
		back, fore = ctx.style.colors[.BUTTON_HOVER if over else .BUTTON], ctx.style.colors[.TEXT]
	}
	render.draw_rounded(ctx, r, back, render.CONTROL_RADIUS)
	mu.draw_icon(ctx, render.icon_id(.Send), r, fore)
	if over {
		ui.hint, ui.hint_of = hint, r
	}
	return pressed
}

// composer_box lays out the box that a composer's message is written in: its
// text area or, with the preview on (see preview_button), the message as it
// will look. It gives the composer the focus when it should have it (which ends
// the preview), and returns what the text area did, the box's id and where it
// is (for composer_buttons).
composer_box :: proc(ui: ^UI, c: Composer) -> (res: mu.Result_Set, box: mu.Id, rect: mu.Rect) {
	ctx := &ui.ctx
	box = mu.get_id(ctx, uintptr(&c.buf[0]))
	rect = mu.layout_next(ctx)
	if c.area.preview {
		// The box's frame, with the preview in the part above the buttons.
		ctx.draw_frame(ctx, rect, .BASE)
		mu.layout_set_next(ctx, text_area_text_rect(rect, c.area), false)
		chat_preview(ui, c)
	} else {
		mu.layout_set_next(ctx, rect, false)
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
// message as it will look in the box's place, and switches back (D8).
preview_button :: proc(ui: ^UI, c: Composer) {
	if .SUBMIT in
	   icon_button(ui, "preview", .Eye, "Back to writing" if c.area.preview else "Preview") {
		c.area.preview = !c.area.preview
		if !c.area.preview {
			focus_composer(ui, c, -1)
		}
	}
}

// chat_preview shows what is in a composer as it will look when sent, in the
// box's place: what is typed is turned into what is stored (mentions, emoji)
// and shown as the timeline shows it, in a panel that scrolls. Call with the
// View locked.
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
		text, color = rich_plain("Nothing to preview yet."), theme.dim
	} else {
		text = message_rich(
			ui,
			conn.emoji_encode(
				conn.mentions_encode(typed, v.accounts, v.roles[:]),
				v.emoji.names[:],
			),
		)
	}
	// Inset as the text area's text is: its padding at the sides, but only
	// what is left of a line in a single line's box above and below. With
	// the panel's whole padding all around, the box that the text area was
	// sized to wouldn't hold it, and the preview would scroll.
	padding := ctx.style.padding
	lh := ctx.text_height(ctx.style.font)
	top := (text_area_single(ctx, ctx.style.font) - lh) / 2
	ctx.style.padding = top
	defer ctx.style.padding = padding
	mu.begin_panel(ctx, fmt.tprintf("composer preview %d", c.thread), {.NO_FRAME})
	defer mu.end_panel(ctx)
	if side := padding - top; side > 0 {
		l := mu.get_layout(ctx)
		l.body.x += side
		l.body.w = max(l.body.w - 2 * side, 1)
	}
	spacing := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = spacing
	mu.layout_row(ctx, {-1}, ctx.text_height(ctx.style.font))
	rich_text(ui, &text, color, 0)
}

// chat_text_area is text_area in the chat's font: the box that a composer's
// message is written in.
chat_text_area :: proc(ui: ^UI, c: Composer) -> mu.Result_Set {
	ctx := &ui.ctx
	saved := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved
	return text_area(ui, c.buf, c.len, c.area)
}

// tab_button is a stable_button that is drawn pressed while its tab is shown.
tab_button :: proc(ctx: ^mu.Context, id_name, label: string, active: bool) -> mu.Result_Set {
	if !active {
		return stable_button(ctx, id_name, label)
	}
	// In the accent color, with its label bold, so that the shown tab can be
	// recognized at a glance.
	saved := ctx.style.colors
	saved_font := ctx.style.font
	ctx.style.colors[.BUTTON] = theme.accent
	ctx.style.colors[.BUTTON_HOVER] = theme.accent_hover
	ctx.style.colors[.BUTTON_FOCUS] = theme.accent_hover
	ctx.style.colors[.TEXT] = theme.accent_text
	ctx.style.font = render.font_with_style(saved_font, .Bold)
	defer ctx.style.colors = saved
	defer ctx.style.font = saved_font
	return stable_button(ctx, id_name, label)
}

@(private = "file")
chat_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	composer := composer_of(ui, 0)
	input_h := composer_height(ui, composer)
	composer_row(ui, input_h)
	composer_input(ui, composer)
	res, box, box_rect := composer_box(ui, composer)
	completion_update(ui, composer)
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil && ui.chat.editing == 0 {
		command(ui, conn.Typing_Command{})
	}
	send := .SUBMIT in res
	composer_buttons(ui, box_rect, 4)
	attach_button(ui, composer)
	emoji_button(ui, composer)
	preview_button(ui, composer)
	if composer_send_button(ui, composer, "send", "Save" if ui.chat.editing != 0 else "Send") {
		send = true
	}
	composer_buttons_end(ui)
	if !send {
		return
	}
	// Enter takes the focus away from the box, so keep typing instead.
	mu.set_focus(ctx, box)
	composer_send(ui, composer)
}

// How long a notice (see conn.notify) shows in the line over a conversation.
@(private = "file")
NOTICE_SHOW :: 5 * time.Second

// chat_status is what the channel's header says at its right end (see
// header_line): that the clipboard is being read, that a message is being
// edited, the network side's latest notice, or who is typing. Call with the
// View locked.
chat_status :: proc(ui: ^UI) -> (status: string, color: mu.Color) {
	v := ui.view
	status = "reading the clipboard..." if ui.paste != nil else typing_text(v)
	color = theme.dim
	if editing := composer_status(composer_of_page(ui)); editing != "" {
		status = editing
	}
	if notice, ok, fresh := fresh_notice(v); fresh {
		status, color = notice, theme.dim if ok else theme.error
	}
	when TIMELINE_DEBUG {
		status = fmt.tprintf(
			"%s  [%d laid out, %d off]",
			status,
			ui.timeline.laid_out,
			ui.timeline.mismatched,
		)
	}
	return
}

// header_line draws a conversation's header in `r`, on one line: `name`, then
// `more` (a channel's topic) dimmed, and `status` (who is typing, or that a
// message is being edited) at the right end. `more` gives way to `status`
// where both don't fit, and `status` to the name.
header_line :: proc(
	ctx: ^mu.Context,
	r: mu.Rect,
	name: string,
	name_color: mu.Color,
	more: string,
	status: string,
	status_color: mu.Color,
) {
	GAP :: 12
	font := ctx.style.font
	y := r.y + (r.h - ctx.text_height(font)) / 2
	x := r.x + ctx.style.padding
	mu.push_clip_rect(ctx, r)
	defer mu.pop_clip_rect(ctx)
	if name != "" {
		mu.draw_text(ctx, font, name, {x, y}, name_color)
		x += ctx.text_width(font, name) + GAP
	}
	end := r.x + r.w - ctx.style.padding
	if status != "" {
		sx := max(end - ctx.text_width(font, status), x)
		mu.draw_text(ctx, font, status, {sx, y}, status_color)
		end = sx - GAP
	}
	if more != "" && end > x {
		mu.push_clip_rect(ctx, {x, r.y, end - x, r.h})
		mu.draw_text(ctx, font, more, {x, y}, theme.dim)
		mu.pop_clip_rect(ctx)
	}
}

// fresh_notice is the notice the network side gave last, if it was
// recent. Call with the View locked.
fresh_notice :: proc(v: ^conn.View) -> (text: string, ok: bool, fresh: bool) {
	if v.notice.text == "" || v.notice.at == {} || time.tick_since(v.notice.at) > NOTICE_SHOW {
		return
	}
	return v.notice.text, v.notice.ok, true
}

// notice_until is when the notice that the network side gave last
// disappears, or zero if it isn't showing. Call with the View locked.
notice_until :: proc(v: ^conn.View) -> time.Tick {
	if _, _, fresh := fresh_notice(v); !fresh {
		return {}
	}
	return time.tick_add(v.notice.at, NOTICE_SHOW)
}

// typing_text says who is typing in the conversation we're looking at
// (or, with `root`, in that thread of it), or returns "". For the conversation,
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

// chat_time formats a message's time in the local time zone, as the locale
// writes it (Date_Style): the time of day for today's messages, and the
// date in short as well for older ones. The buddy screen uses it too, for when
// someone was last online.
chat_time :: proc(ui: ^UI, unix: proto.Unix_Time) -> string {
	local :: proc(ui: ^UI, t: time.Time) -> datetime.DateTime {
		dt, _ := time.time_to_datetime(t)
		return chat_local_time(ui, dt)
	}
	dt := local(ui, time.unix(i64(unix), 0))
	now := local(ui, time.now())
	return date_time_text(ui.date_style, dt, dt.date == now.date)
}

// How the locale writes a date in short and a time of day: the order of the
// day, month and year, what goes between them, and whether the clock has
// twelve hours with AM and PM.
Date_Order :: enum {
	DMY, // 31/9/26
	MDY, // 9/31/26
	YMD, // 2026-9-31
}

Date_Style :: struct {
	order:  Date_Order,
	sep:    u8,
	hour12: bool,
}

// date_style_of works out a Date_Style from a locale's name, as the system
// gives it ("en_US.UTF-8", "en-US", "de"). Without one, or for one it doesn't
// know, it is the day first and a 24 hour clock.
date_style_of :: proc(locale: string) -> (style: Date_Style) {
	name := strings.to_lower(locale, context.temp_allocator)
	if i := strings.index_any(name, ".@"); i >= 0 {
		name = name[:i]
	}
	lang, region := name, ""
	if i := strings.index_any(name, "_-"); i >= 0 {
		lang, region = name[:i], name[i + 1:]
	}
	has :: proc(list: []string, s: string) -> bool {
		for l in list {
			if l == s {
				return true
			}
		}
		return false
	}
	style = {.DMY, '/', false}
	switch {
	case (lang == "en" && has({"", "us", "ph"}, region)) || (lang == "es" && region == "us"):
		style.order = .MDY
	case has({"zh", "ja"}, lang):
		style.order = .YMD
	case has({"ko", "hu", "lt", "sv", "mn"}, lang) || (region == "ca" && has({"en", "fr"}, lang)):
		style.order, style.sep = .YMD, '-'
	case has(
		     {
			     "de",
			     "ru",
			     "pl",
			     "fi",
			     "cs",
			     "sk",
			     "nb",
			     "nn",
			     "no",
			     "da",
			     "tr",
			     "uk",
			     "ro",
			     "hr",
			     "sl",
			     "sr",
			     "bg",
			     "et",
			     "lv",
			     "is",
			     "be",
			     "kk",
			     "az",
		     },
		     lang,
	     ):
		style.sep = '.'
	case lang == "nl":
		style.sep = '-'
	}
	style.hour12 =
		(lang == "en" && has({"", "us", "ca", "au", "nz", "in", "ph"}, region)) ||
		(lang == "es" && region == "us") ||
		has({"hi", "ko"}, lang)
	return
}

// date_time_text writes `dt` as `style` says: only the time of day with
// `today`, otherwise the date in short before it (with the year's last two
// digits, or all four when the year comes first).
date_time_text :: proc(style: Date_Style, dt: datetime.DateTime, today: bool) -> string {
	clock: string
	if style.hour12 {
		h := dt.hour % 12
		clock = fmt.tprintf(
			"%d:%02d %s",
			12 if h == 0 else h,
			dt.minute,
			"PM" if dt.hour >= 12 else "AM",
		)
	} else {
		clock = fmt.tprintf("%02d:%02d", dt.hour, dt.minute)
	}
	if today {
		return clock
	}
	s := rune(style.sep)
	date: string
	switch style.order {
	case .DMY:
		date = fmt.tprintf("%d%r%d%r%02d", dt.day, s, dt.month, s, dt.year % 100)
	case .MDY:
		date = fmt.tprintf("%d%r%d%r%02d", dt.month, s, dt.day, s, dt.year % 100)
	case .YMD:
		date = fmt.tprintf("%d%r%d%r%d", dt.year, s, dt.month, s, dt.day)
	}
	return fmt.tprintf("%s %s", date, clock)
}

// chat_same_minute says whether two messages are shown as part of the same
// block: close enough in time that showing both their headers would
// just repeat the same sender and (usually) the same minute.
chat_same_minute :: proc(a, b: proto.Unix_Time) -> bool {
	return a / 60 == b / 60
}

// How much closer together a merged message sits, compared with the usual gap
// between two separate ones (ctx.style.spacing).
MERGED_GAP :: 1

// chat_block_height is how far chat_message or file_message moves the
// layout down, `body` being the height of what is under the header (the
// text's lines). The timeline uses it to work out where messages
// are without laying them out, so it has to agree with those two.
chat_block_height :: proc(ctx: ^mu.Context, merged: bool, body: i32, tight := false) -> i32 {
	line := ctx.text_height(ctx.style.font)
	h := (MERGED_GAP if merged || tight else ctx.style.spacing) + (0 if merged else line) + body
	// The one-pixel row that the block's column starts on, and its spacing.
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

// file_message draws a file offer in a conversation: the header, the file's
// name and size, how it is going (with a bar while it is under way, and room
// for one otherwise), and the buttons that fit: Accept and Decline for a file
// offered to us, and Cancel while the transfer isn't over. file_block_height has
// to agree with it.
file_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	id: proto.Msg_Id,
	f: conn.View_File,
	merged: bool,
	item: i64, // the header's. The file's name and state are the next two
	tight := false, // as in chat_message
) {
	ctx := &ui.ctx
	font := ctx.style.font
	// 1, not 0: see the same line in chat_message.
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

	// The bar, below the name, while it is under way. Its room is reserved either way.
	mu.layout_row(ctx, {-1}, FILE_BAR_GAP)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {-1}, FILE_BAR)
	r := mu.layout_next(ctx)
	if f.state == .Transferring {
		r.w = min(r.w, 300)
		mu.draw_rect(ctx, r, theme.track)
		done := f32(f.done) / f32(max(f.size, 1))
		mu.draw_rect(ctx, {r.x, r.y, i32(f32(r.w) * clamp(done, 0, 1)), r.h}, theme.speaking)
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

// file_status says how a transfer is going, and in what color.
@(private = "file")
file_status :: proc(f: conn.View_File) -> (string, mu.Color) {
	switch f.state {
	case .Unknown:
		return "offered earlier, or on another device" if !f.outgoing else "offered from another device",
			theme.dim
	case .Posting:
		return "offering...", theme.dim
	case .Offered:
		return "waiting for them to accept", theme.dim
	case .Incoming:
		return "wants to send you this", theme.chat_name
	case .Starting:
		return "starting...", theme.dim
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
		return text, theme.dim
	case .Done:
		if f.outgoing {
			return "sent", theme.speaking
		}
		when platform.WEB {
			return "downloaded", theme.speaking
		} else {
			return fmt.tprintf("saved to %s", f.path), theme.speaking
		}
	case .Declined:
		return "declined" if !f.outgoing else "they declined", theme.dim
	case .Cancelled:
		return "cancelled", theme.dim
	case .Failed:
		return "failed", theme.off
	case .Interrupted:
		return "stopped: one side left", theme.off
	case .Expired:
		return "no longer available", theme.dim
	case .Elsewhere:
		return "answered on another of your devices", theme.dim
	}
	return "", theme.dim
}

// chat_message draws the gap before this message, a header line unless
// `merged` (in which case it is part of the previous message's block and
// sits right under it instead), and the text under it (see ui_rich_text.odin),
// with the lines packed tightly. `tight` is a header with the gap of a
// merged one, used under a reply's line.
chat_message :: proc(
	ui: ^UI,
	header: string,
	header_color: mu.Color,
	text: ^Rich,
	color: mu.Color,
	merged: bool,
	item: i64, // the header's. The text is the next one
	tight := false,
) {
	ctx := &ui.ctx
	font := ctx.style.font
	// 1, not 0: a height of 0 tells layout_row to fall back to the
	// default control size, which (plus the parent's own row spacing)
	// would set a lower limit on how short this block can be, taller than
	// a merged one-liner is supposed to end up.
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
	if at := ui.header_bot; at > 0 && at <= len(header) {
		bot_tag(ctx, r.x + ctx.text_width(ctx.style.font, header[:at]), r.y)
	}
	if ui.header_sender != 0 {
		font := ctx.style.font
		lo, hi := ui.header_name[0], ui.header_name[1]
		x := r.x + ctx.text_width(font, header[:lo])
		hit := mu.Rect{x, r.y, ctx.text_width(font, header[lo:hi]), r.h}
		if mu.mouse_over(ctx, hit) {
			ui.chat.hovering = true // show a hand, as over a link
			if clicked_not_dragged(ui) {
				open_user_menu(ui, 0, ui.header_sender)
			}
		}
	}
}

// clicked_not_dragged returns whether the left button was released in this
// panel's text without a press that selected something, as for a link
// (see ui_rich_text.odin).
clicked_not_dragged :: proc(ui: ^UI) -> bool {
	return(
		.LEFT in ui.ctx.mouse_released_bits &&
		ui.select.dragging &&
		ui.select.panel == ui.select.drawing &&
		!has_selection(&ui.select, ui.select.drawing) \
	)
}

// wrapped_text is mu.text, except that it also breaks words that are too long for a
// line, wraps the last word of a paragraph (which mu.text doesn't) and
// breaks lines at newlines. It continues the current row layout. The
// text can be selected as `item`. It is meant for plain text (a file's name).
// A message's text uses rich_text instead.
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
// its text is (see render.CHAT_FONT).
custom_emoji_size :: proc(ctx: ^mu.Context) -> (size, advance: i32) {
	zoom := f32(ctx.text_height(ctx.style.font)) / render.LINE_HEIGHT
	return i32(render.CUSTOM_EMOJI_SIZE * zoom), i32(render.CUSTOM_EMOJI_ADVANCE * zoom)
}

// wrap_line returns the first line of `text` wrapped at `width`, as the chat
// wraps it: text[:end] is drawn, and the next line starts at `next`
// (after the newline or the spaces it broke at).
wrap_line :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> (end, next: int) {
	end = line_end(ctx, font, text, width)
	return end, len(text) - len(next_line(text, end))
}

// line_end is how much of `text` fits in `width`: up to the first
// newline if that fits, otherwise up to the last space that fits, or as many
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

// next_line is what is left of `text` after a line of it that ended at
// `end` (see line_end): after the newline that ended it, or after the spaces it
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
