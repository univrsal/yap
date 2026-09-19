package client

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
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
}

CHAT_NAME_COLOR :: mu.Color{120, 170, 230, 255}
CHAT_OWN_COLOR :: mu.Color{140, 200, 140, 255}
CHAT_DIM_COLOR :: mu.Color{140, 140, 140, 255}

ui_chat_init :: proc(ui: ^UI) {
	ui.chat.tz, _ = timezone.region_load("local")
}

ui_chat_destroy :: proc(ui: ^UI) {
	timezone.region_destroy(ui.chat.tz)
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
	with_text_color(ctx, CHAT_DIM_COLOR, typing_text(v), label_proc)

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
		chat_message(ctx, header, CHAT_OWN_COLOR if line.sender == v.my_num else CHAT_NAME_COLOR, line.text, ctx.style.colors[.TEXT])
	}
	for text in v.outbox {
		chat_message(ctx, "sending...", CHAT_DIM_COLOR, text, CHAT_DIM_COLOR)
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
	mu.layout_row(ctx, {-70, -1})
	res := mu.textbox(ctx, ui.chat.buf[:], &ui.chat.len)
	box := ctx.last_id
	if .CHANGE in res && ui.chat.len > 0 && ui.session != nil {
		push_command(&ui.session.client.commands, Typing_Command{})
	}
	send := .SUBMIT in res
	if .SUBMIT in mu.button(ctx, "Send") {
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
		if ui.chat.tz != nil {
			if l, ok := timezone.datetime_to_tz(dt, ui.chat.tz); ok {
				return l
			}
		}
		return dt
	}
	dt := local(ui, time.unix(i64(unix), 0))
	now := local(ui, time.now())
	if dt.date == now.date {
		return fmt.tprintf("%02d:%02d", dt.hour, dt.minute)
	}
	return fmt.tprintf("%d-%02d-%02d %02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute)
}

// chat_message draws a header line and the wrapped text under it, with
// the lines packed tightly and a gap before the next message.
@(private = "file")
chat_message :: proc(ctx: ^mu.Context, header: string, header_color: mu.Color, text: string, color: mu.Color) {
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
	wrapped_text(ctx, text, color)
	mu.layout_row(ctx, {-1}, saved) // the gap
	mu.layout_next(ctx)
}

// wrapped_text is mu.text, except it also breaks words too long for a
// line, and wraps the last word of a paragraph (which mu.text doesn't).
// It continues the current row layout.
@(private = "file")
wrapped_text :: proc(ctx: ^mu.Context, text: string, color: mu.Color) {
	font := ctx.style.font
	text := text
	for len(text) > 0 {
		r := mu.layout_next(ctx)
		end := line_end(ctx, font, text, r.w)
		mu.draw_text(ctx, font, text[:end], {r.x, r.y}, color)
		text = strings.trim_left_space(text[end:])
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
