package client

import "core:fmt"
import log "../common/wlog"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:unicode/utf8"
import mu "vendor:microui"

import "../proto"

/*
The right-hand side of the session screen: the channel's text chat and
the log, as tabs.
*/

Side_Tab :: enum {
	Chat,
	Log,
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
		open_url(ui.chat.open)
		delete(ui.chat.open)
		ui.chat.open = ""
	}
	if ui.chat.paste {
		ui.chat.paste = false
		paste_start(ui)
	}
	paste_poll(ui)
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
	mu.layout_row(ctx, {90, 90, -1})
	chat_label := "Chat" if v.chat_unread == 0 else fmt.tprintf("Chat (%d)", v.chat_unread)
	if .SUBMIT in tab_button(ctx, "chat tab", chat_label, ui.chat.tab == .Chat) {
		ui.chat.tab = .Chat
		ui.chat.scrolled = -1 // back to the newest messages
	}
	if .SUBMIT in tab_button(ctx, "log tab", "Log", ui.chat.tab == .Log) {
		ui.chat.tab = .Log
		ui.log_seen = -1
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
	if len(v.chat) == 0 && len(v.outbox) == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, CHAT_DIM_COLOR, "No messages in this channel yet.", label_proc)
	}
	for line in v.chat {
		header := fmt.tprintf("%s  %s", chat_time(ui, line.time), line.name)
		header_color := CHAT_OWN_COLOR if line.sender == v.my_num else CHAT_NAME_COLOR
		switch line.kind {
		case .Text:
			chat_message(ui, header, header_color, line.text, ctx.style.colors[.TEXT], links = true)
		case .Image:
			img := v.images[line.image.id] or_else {}
			chat_image(ui, header, header_color, line.image, img)
		}
	}
	for text in v.outbox {
		chat_message(ui, "sending...", CHAT_DIM_COLOR, text, CHAT_DIM_COLOR, links = false)
	}
	mu.end_panel(ctx)

	// Follow new messages.
	if seen := v.chat_total + len(v.outbox); seen != ui.chat.scrolled {
		ui.chat.scrolled = seen
		cnt.scroll.y = cnt.content_size.y
	}
}

@(private = "file")
chat_input :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-(ICON_BUTTON + 6), ICON_BUTTON})
	// Ctrl+V could be an image: hold the text paste back and decide after
	// the frame (see paste). The id is the one mu.textbox uses.
	if ctx.focus_id == mu.get_id(ctx, uintptr(&ui.chat.buf[0])) &&
	   .V in ctx.key_pressed_bits &&
	   .CTRL in ctx.key_down_bits &&
	   .ALT not_in ctx.key_down_bits {
		ctx.key_pressed_bits -= {.V}
		ui.chat.paste = true
	}
	res := mu.textbox(ctx, ui.chat.buf[:], &ui.chat.len)
	box := ctx.last_id
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil {
		push_command(&ui.session.client.commands, Typing_Command{})
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
	push_command(&ui.session.client.commands, Chat_Command{strings.clone(text)})
	ui.chat.len = 0
}

// typing_text says who in our channel is typing, or "".
@(private = "file")
typing_text :: proc(v: ^View) -> string {
	if v.my_channel < 0 || v.my_channel >= len(v.channels) {
		return ""
	}
	names := make([dynamic]string, context.temp_allocator)
	for m in v.channels[v.my_channel].members {
		if m != v.my_num && is_typing(v, m) {
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
// for today's messages, with the date for older ones.
@(private = "file")
chat_time :: proc(ui: ^UI, unix: u32) -> string {
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

// chat_image draws an image message: the header, then the picture.
@(private = "file")
chat_image :: proc(ui: ^UI, header: string, header_color: mu.Color, info: proto.Image_Info, img: View_Image) {
	ctx := &ui.ctx
	font := ctx.style.font
	mu.layout_row(ctx, {-1}, 0)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	saved := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved

	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	r := mu.layout_next(ctx)
	mu.draw_text(ctx, font, header, {r.x, r.y}, header_color)
	// An image the server has dropped has no id left to look it up by.
	state := img.state if info.id != 0 else Image_State.Gone
	image_block(ui, info, state, img.jpeg)
	mu.layout_row(ctx, {-1}, saved) // the gap
	mu.layout_next(ctx)
}

// chat_message draws a header line and the wrapped text under it, with
// the lines packed tightly and a gap before the next message.
@(private = "file")
chat_message :: proc(ui: ^UI, header: string, header_color: mu.Color, text: string, color: mu.Color, links: bool) {
	ctx := &ui.ctx
	font := ctx.style.font
	mu.layout_row(ctx, {-1}, 0)
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	saved := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved

	r := mu.layout_next(ctx)
	mu.draw_text(ctx, font, header, {r.x, r.y}, header_color)
	wrapped_text(ui, text, color, find_links(text) if links else nil)
	mu.layout_row(ctx, {-1}, saved) // the gap
	mu.layout_next(ctx)
}

// wrapped_text is mu.text, except it also breaks words too long for a
// line, wraps the last word of a paragraph (which mu.text doesn't), and
// draws `links` (byte ranges of `text`) as clickable links. It continues
// the current row layout.
@(private = "file")
wrapped_text :: proc(ui: ^UI, text: string, color: mu.Color, links: []Link) {
	ctx := &ui.ctx
	font := ctx.style.font
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end := line_end(ctx, font, rest, r.w)
		start := len(text) - len(rest)
		draw_line(ui, text, start, start + end, {r.x, r.y}, color, links)
		rest = strings.trim_left_space(rest[end:])
	}
}

// draw_line draws text[start:end], in pieces where it overlaps links.
@(private = "file")
draw_line :: proc(ui: ^UI, text: string, start, end: int, pos: mu.Vec2, color: mu.Color, links: []Link) {
	ctx := &ui.ctx
	font := ctx.style.font
	x := pos.x
	piece :: proc(ctx: ^mu.Context, font: mu.Font, s: string, x: ^i32, y: i32, color: mu.Color) -> mu.Rect {
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
		r := piece(ctx, font, text[at:link_end], &x, pos.y, LINK_HOVER_COLOR if hovered else LINK_COLOR)
		// Underline, just below the baseline.
		mu.draw_rect(ctx, {r.x, r.y + r.h - 2, r.w, 1}, LINK_HOVER_COLOR if hovered else LINK_COLOR)
		if mu.mouse_over(ctx, r) {
			ui.chat.hover = id
			ui.chat.hovering = true
			if .LEFT in ctx.mouse_pressed_bits && ui.chat.open == "" {
				ui.chat.open = link_url(text, l, context.allocator)
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
