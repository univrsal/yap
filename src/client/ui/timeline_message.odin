package ui

import "core"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:richtext"
import "common:proto"

// timeline_message draws msgs[i] and says where in the layout the message
// itself starts (after a day's line, the "new messages" line, and the gap
// above a header).
timeline_message :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	msgs: []conn.View_Message,
	i: int,
	full: i32,
	readonly := false,
) -> (
	from: i32,
) {
	ctx := &ui.ctx
	v := ui.view
	m := msgs[i]
	new_day, new_line, merged, tight := message_flags(ui, st, msgs, i)
	seconds := proto.Unix_Time(m.time / 1000)
	if new_day {
		day_line(ui, seconds)
	}
	if new_line {
		rule(ui, "New messages", core.theme.new_line)
	}
	// A reply is indented: everything of it from here on.
	indent: i32 = REPLY_INDENT if is_indented(st, m) else 0
	time_w := message_time_w(st, m.time)
	column := message_column(ui, time_w)
	width := full - indent - column
	mu.get_layout(ctx).indent += indent + column
	defer mu.get_layout(ctx).indent -= indent + column
	from = mu.get_layout(ctx).next_row + (0 if merged else ctx.style.spacing)
	if tight {
		// Its reply's line, and the message right under it.
		from = mu.get_layout(ctx).next_row + 1 + ctx.style.spacing
		reply_line(ui, st, m, width, readonly)
	}
	defer if has_thread_line(st, m) {
		thread_line(ui, st, m, readonly)
	}
	name := "someone"
	if acc, ok := v.accounts[m.sender]; ok {
		name = acc.display
	}
	// A bot's message under another name shows that name, and the bot's own
	// after it (persona_note).
	persona := .Persona in m.flags
	via := ""
	if persona {
		via = name
		name = m.persona.name
	}
	// Their name is bold, and opens their menu unless it is ours.
	ui.header_sender = 0
	ui.header_name = {}
	if !merged {
		ui.header_name = {0, len(name)}
		if m.sender != v.me {
			ui.header_sender = m.sender
		}
	}
	defer ui.header_sender, ui.header_name = 0, {}
	// Room for a bot's tag after the name, which selectable_header draws.
	bot_room := ""
	ui.header_bot = 0
	if !merged && is_bot(v, m.sender) {
		ui.header_bot = len(name)
		bot_room = header_room(ctx, bot_tag_width(ctx))
	}
	defer ui.header_bot = 0
	// With the pictures, the time follows the name (and tag), dimmed.
	stamp := chat_time(ui, seconds)
	when_room := ""
	ui.header_time = {}
	if !merged && ui.settings.chat_pictures {
		at := len(name) + len(bot_room) + 2
		ui.header_time = {at, at + len(stamp)}
		when_room = fmt.tprintf("  %s", stamp)
	}
	defer ui.header_time = {}
	header :=
		"" if merged else fmt.tprintf("%s%s%s%s%s%s", name, bot_room, when_room, "  (edited)" if m.edited != 0 && .Deleted not_in m.flags else "", forward_note(ui, m), fmt.tprintf("  - via %s", via) if persona else "")
	header_color := core.theme.chat_name if persona else author_color(v, m.sender)
	item := i64(m.id) * ITEMS_PER_MESSAGE
	if !merged {
		// The picture beside the header, or in the compact chat, the time on
		// the header's line (which comes after the gap) and then the dot.
		layout := mu.get_layout(ctx)
		y := layout.body.y + layout.next_row + (MERGED_GAP if tight else ctx.style.spacing)
		x := layout.body.x + indent
		if !ui.settings.chat_pictures {
			stamp_x := x + time_w - TIME_GAP - ctx.text_width(ctx.style.font, stamp)
			mu.draw_text(ctx, ctx.style.font, stamp, {stamp_x, y}, ctx.style.colors[.TEXT])
		}
		x += time_w
		if ui.settings.chat_pictures {
			size := avatar_size(ctx)
			pic := mu.Rect{x, y, size, size}
			if persona {
				persona_picture(ui, m.persona, m.sender, pic)
			} else {
				avatar(ui, m.sender, pic)
			}
			if m.sender != v.me && mu.mouse_over(ctx, pic) {
				ui.chat.hovering = true // shows a hand, as over a link
				if clicked_not_dragged(ui) {
					open_user_menu(ui, 0, m.sender)
				}
			}
		} else {
			activity_dot_alone(
				ui,
				m.sender,
				{x, y, COMPACT_DOT_COLUMN, ctx.text_height(ctx.style.font)},
			)
		}
	}
	if .Deleted in m.flags {
		text := rich_plain(DELETED_TEXT)
		chat_message(ui, header, header_color, &text, core.theme.dim, merged, item, tight)
		return from
	}
	#partial switch m.kind {
	case .File:
		file_message(ui, header, header_color, m.id, message_file(v, m), merged, item, tight)
	case .Text:
		text := message_rich(ui, m.text)
		chat_message(ui, header, header_color, &text, ctx.style.colors[.TEXT], merged, item, tight)
		message_files(ui, st.key.conv, m, width)
	case .System:
		text := rich_plain(system_line(ui, m))
		chat_message(ui, header, header_color, &text, core.theme.dim, merged, item, tight)
	case:
		text := rich_plain(UNKNOWN_KIND_TEXT)
		chat_message(ui, header, header_color, &text, core.theme.dim, merged, item, tight)
	}
	reaction_chips(ui, m, width, readonly)
	return from
}

// reply_line is the dim line above a reply: a mark, then who wrote the message
// it replies to and the start of that message, cut to the width. Until the
// root is here it only says that this is a reply, and the root is requested.
// Clicking it opens the thread.
@(private = "file")
reply_line :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	m: conn.View_Message,
	width: i32,
	readonly := false,
) {
	ctx := &ui.ctx
	v := ui.view
	font := ctx.style.font
	mu.layout_row(ctx, {-1}, 1)
	mu.layout_next(ctx) // the gap above it
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	r := mu.layout_next(ctx)

	key := conn.Timeline_Key{st.key.conv, m.thread_root}
	text := "reply in a thread"
	if root, ok := thread_root_message(ui, key); ok {
		name := "someone"
		if acc, known := v.accounts[root.sender]; known {
			name = acc.display
		}
		said: string
		switch {
		case .Deleted in root.flags:
			said = DELETED_TEXT
		case root.text == "" && len(root.files) > 0:
			said = files_said(root.files)
		case root.kind == .File:
			said = fmt.tprintf("the file %s", root.text)
		case:
			shown, _ := richtext.mentions_display(root.text, v.accounts, v.roles[:], v.me)
			said = richtext.markdown_plain(shown)
		}
		said = richtext.one_line(said)
		text = fmt.tprintf("%s: %s", name, said)
	} else if !st.roots_asked[m.thread_root] && ui.session != nil {
		st.roots_asked[m.thread_root] = true
		conn.push_command(
			&ui.session.client.commands,
			conn.Root_Command{conv = key.conv, root = key.root},
		)
	}
	text = cut_to_width(
		ctx,
		strings.concatenate({REPLY_MARK, text}, context.temp_allocator),
		width,
	)
	if thread_link(ui, text, r, core.theme.dim) {
		open_thread(ui, key, readonly)
	}
}

// thread_line is the line under a root with replies: how many, and when the
// last one was, if it is here. Clicking it opens the thread.
@(private = "file")
thread_line :: proc(ui: ^UI, st: ^UI_Timeline, m: conn.View_Message, readonly := false) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, ctx.text_height(ctx.style.font))
	r := mu.layout_next(ctx)
	text := "1 reply" if m.reply_count == 1 else fmt.tprintf("%d replies", m.reply_count)
	if tl, ok := ui.view.timelines[{st.key.conv, 0}]; ok {
		if i, found := message_index(tl.messages[:], m.last_reply); found {
			text = fmt.tprintf(
				"%s \u00b7 last at %s",
				text,
				chat_time(ui, proto.Unix_Time(tl.messages[i].time / 1000)),
			)
		}
	}
	if thread_link(ui, text, r, core.theme.chat_name) {
		open_thread(ui, {st.key.conv, m.id}, readonly)
	}
}

// thread_link draws a line that opens a thread, in `r`, highlighted while the
// pointer is over it. It returns true when it is clicked.
@(private = "file")
thread_link :: proc(ui: ^UI, text: string, r: mu.Rect, color: mu.Color) -> bool {
	ctx := &ui.ctx
	font := ctx.style.font
	hit := mu.Rect{r.x, r.y, min(ctx.text_width(font, text), r.w), r.h}
	over := mu.mouse_over(ctx, hit)
	mu.draw_text(ctx, font, text, {r.x, r.y}, core.theme.link_hover if over else color)
	if !over {
		return false
	}
	ui.chat.hovering = true // shows a hand, as over a link
	return .LEFT in ctx.mouse_pressed_bits
}

// cut_to_width is `text`, cut with an ellipsis to fit `width`.
cut_to_width :: proc(ctx: ^mu.Context, text: string, width: i32) -> string {
	font := ctx.style.font
	if ctx.text_width(font, text) <= width {
		return text
	}
	ellipsis :: "\u2026"
	room := width - ctx.text_width(font, ellipsis)
	end := 0
	for _, i in text {
		if ctx.text_width(font, text[:i]) > room {
			break
		}
		end = i
	}
	return strings.concatenate({text[:end], ellipsis}, context.temp_allocator)
}

// system_line is what a system message says: a call's line, with a phone in
// front of it, or what happened in the channel or on the server.
system_line :: proc(env: ^core.Env, m: conn.View_Message) -> string {
	v := env.view
	name_of :: proc(v: ^conn.View, id: proto.Account_Id) -> string {
		if acc, ok := v.accounts[id]; ok {
			return acc.display
		}
		return "someone"
	}
	text := conn.system_text(
		m.system,
		m.system_arg,
		m.text,
		name_of(v, m.sender),
		name_of(v, proto.Account_Id(m.system_arg)),
		m.sender == v.me,
	)
	if proto.system_counts_unread(m.system) {
		return fmt.tprintf("\U0001F4DE %s", text)
	}
	return text
}

// What is left of a deleted message.
DELETED_TEXT :: "message deleted"

// message_mouse is what the pointer does to a message laid out in `block`:
// pointing at it shows the message's bar over it, and a right click opens its
// menu. The message that was jumped to is highlighted for a while, and when it
// was jumped to as the first unread mention of us, the others are
// highlighted too.
message_mouse :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	m: conn.View_Message,
	block: mu.Rect,
	readonly := false,
) {
	ctx := &ui.ctx
	lit := st.lit == m.id
	if st.lit_mentions && st.lit_at != {} && m.id > st.unread_from && m.kind == .Text {
		lit ||= proto.mentions_account(m.text, ui.view.me, ui.view.accounts[ui.view.me].roles)
	}
	if lit {
		if since := time.tick_since(st.lit_at); since < JUMP_HIGHLIGHT {
			fade := 1 - f32(since) / f32(JUMP_HIGHLIGHT)
			core.redraw_in(ui, core.ANIMATION_FRAME)
			mu.draw_rect(ctx, block, {255, 220, 120, u8(50 * fade)})
		} else {
			st.lit, st.lit_mentions = 0, false
		}
	}
	message_marks(ui, m, block)
	if !readonly {
		message_bar_track(ui, st.key.conv, st.slot, m, block)
		if .RIGHT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, block) {
			open_message_menu(ui, m, st.slot)
		}
	}
}

// message_marks draws a pin and a bookmark at the top right of a message that
// is pinned or bookmarked. The hover bar covers them while it is shown.
@(private = "file")
message_marks :: proc(ui: ^UI, m: conn.View_Message, block: mu.Rect) {
	ctx := &ui.ctx
	if .Deleted in m.flags {
		return
	}
	size := ctx.text_height(ctx.style.font)
	x := block.x + block.w - MARK_INSET - size
	y := block.y + MARK_INSET / 2
	if mu.check_clip(ctx, {x - size, y, 2 * size, size}) == .ALL {
		return
	}
	if ui.view.bookmarks.ids[m.id] {
		mu.draw_icon(ctx, render.icon_id(.Bookmark), {x, y, size, size}, core.theme.accent)
		x -= size
	}
	if .Pinned in m.flags {
		mu.draw_icon(ctx, render.icon_id(.Pin), {x, y, size, size}, core.theme.pinned)
	}
}

// How far in from the message's right edge its marks sit.
@(private = "file")
MARK_INSET :: 8

// day_line is the line above the first message of a day.
@(private = "file")
day_line :: proc(ui: ^UI, seconds: proto.Unix_Time) {
	dt, _ := time.time_to_datetime(time.unix(i64(seconds), 0))
	local := chat_local_time(ui, dt)
	now, _ := time.time_to_datetime(time.now())
	today := chat_local_time(ui, now)
	text: string
	switch {
	case local.date == today.date:
		text = "Today"
	case:
		ordinal, _ := datetime.date_to_ordinal(local.date)
		weekday := datetime.day_of_week(ordinal)
		text = fmt.tprintf("%v, %d-%02d-%02d", weekday, local.year, local.month, local.day)
	}
	rule(ui, text, core.theme.day_line)
}

// rule is a line across the timeline with `text` in the middle of it, in a row
// of the usual height.
rule :: proc(env: ^core.Env, text: string, color: mu.Color) {
	ctx := &env.ctx
	mu.layout_row(ctx, {-1})
	r := mu.layout_next(ctx)
	font := ctx.style.font
	w := ctx.text_width(font, text)
	mid := r.y + r.h / 2
	x := r.x + (r.w - w) / 2
	mu.draw_rect(ctx, {r.x, mid, max(x - r.x - 8, 0), 1}, color)
	mu.draw_rect(ctx, {x + w + 8, mid, max(r.x + r.w - x - w - 8, 0), 1}, color)
	mu.draw_text(ctx, font, text, {x, r.y + (r.h - ctx.text_height(font)) / 2}, color)
}
