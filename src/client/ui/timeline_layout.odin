package ui

import "widgets"
import "core"
import "core:fmt"
import "core:time"
import "core:time/datetime"
import mu "vendor:microui"

import "client:conn"
import "client:richtext"
import "common:proto"

// thread_head draws a thread's root above its replies (or a line saying that
// it is on its way), as tall as the timeline works out.
thread_head :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	root: conn.View_Message,
	have: bool,
	width: i32,
	readonly := false,
) {
	ctx := &ui.ctx
	if !have {
		mu.layout_row(ctx, {-1})
		widgets.dim_label(ctx, "Loading the message replied to...")
		return
	}
	layout := mu.get_layout(ctx)
	from := timeline_message(ui, st, {root}, 0, width)
	message_mouse(
		ui,
		st,
		root,
		{layout.body.x, layout.body.y + from, width, layout.next_row - from},
		readonly,
	)
}

// message_flags says whether a message starts a day (and gets the day's
// line), whether the unread messages start with it (and it gets the "new
// messages" line), and whether it is drawn as part of the one before.
message_flags :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	msgs: []conn.View_Message,
	i: int,
) -> (
	new_day, new_line, merged, reply_line: bool,
) {
	in_thread := st.key.root != 0
	if i == 0 && in_thread && msgs[0].id != st.key.root {
		// The first reply, under the root.
		return st.root_day == 0 || local_day(ui, st, msgs[0]) != st.root_day, false, false, false
	}
	if i == 0 {
		// Above the first message shown only if it is the conversation's
		// first: otherwise the line's place may be further up, not loaded yet.
		return true,
			st.unread_line && st.at_start && msgs[0].id > st.unread_from,
			false,
			!in_thread && msgs[0].thread_root != 0
	}
	m, prev := msgs[i], msgs[i - 1]
	from := st.unread_from
	new_day = local_day(ui, st, m) != local_day(ui, st, prev)
	new_line = st.unread_line && prev.id <= from && m.id > from
	// Once for replies to the same thread in a row, and never merged with
	// anything but them.
	reply_line = !in_thread && m.thread_root != 0 && m.thread_root != prev.thread_root
	merged =
		!new_day &&
		!new_line &&
		m.thread_root == prev.thread_root &&
		!has_thread_line(st, prev) &&
		m.edited == 0 &&
		m.flags & {.Deleted, .Pinned, .Forwarded} == {} &&
		!ui.view.bookmarks.ids[m.id] &&
		m.sender == prev.sender &&
		m.persona == prev.persona &&
		chat_same_minute(proto.Unix_Time(m.time / 1000), proto.Unix_Time(prev.time / 1000)) // so that its header says so// a bot's other persona has its own header
	return
}

// is_indented is whether a message is drawn as a reply: indented, with a bar
// beside it. This only applies in its conversation's timeline, not in its
// thread's.
is_indented :: proc(st: ^UI_Timeline, m: conn.View_Message) -> bool {
	return st.key.root == 0 && m.thread_root != 0
}

// has_thread_line is whether a message has its thread's line under it: a root
// with replies, in its conversation's timeline.
has_thread_line :: proc(st: ^UI_Timeline, m: conn.View_Message) -> bool {
	return st.key.root == 0 && .Has_Thread in m.flags && m.reply_count > 0
}

// The heights of a reply's line (and the gap above it) and of a root's thread
// line.
@(private = "file")
reply_line_height :: proc(ctx: ^mu.Context) -> i32 {
	return 1 + ctx.text_height(ctx.style.font) + 2 * ctx.style.spacing
}
@(private = "file")
thread_line_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.text_height(ctx.style.font) + ctx.style.spacing
}

// Each message has up to this many items to select from (ui/select.odin): its
// header and text, or a file's header, name and state.
ITEMS_PER_MESSAGE :: 4

// pending_message draws a message of ours that is on its way.
pending_message :: proc(ui: ^UI, p: conn.View_Pending, item: i64) {
	text: Rich
	#partial switch p.kind {
	case .File:
		text = rich_plain(fmt.tprintf("the file %s", p.text))
	case:
		shown, spans, emoji := richtext.text_display(
			p.text,
			ui.view.accounts,
			ui.view.roles[:],
			ui.view.me,
			ui.view.emoji.names[:],
		)
		text = rich_make(shown, spans, emoji, nil, false)
	}
	status := "sending files..." if p.uploading else "sending..."
	chat_message(ui, status, core.theme.dim, &text, core.theme.dim, false, item)
	pending_files(ui, p)
}

// viewed_unread is what is unread in the conversation being looked at, up to
// where it has been read, and how many of the unread messages mention us. Call
// with the View locked.
viewed_unread :: proc(v: ^conn.View) -> (unread: int, read: proto.Msg_Id, mentions: int) {
	if ch := viewed_channel(v); ch != nil {
		return ch.unread, ch.read, ch.mentions
	}
	for dm in v.dms {
		if dm.id == v.viewing {
			return dm.unread, dm.read, dm.mentions
		}
	}
	return
}

// message_file is what is known about a file that a message offers: how its
// transfer is going, if there is one here.
message_file :: proc(v: ^conn.View, m: conn.View_Message) -> conn.View_File {
	if f, ok := v.files[m.id]; ok {
		return f
	}
	return {name = m.text, size = m.file_size, outgoing = m.sender == v.me, state = .Unknown}
}

// message_height is how far drawing msgs[i] at `width` moves the layout down
// (timeline_message).
message_height :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	msgs: []conn.View_Message,
	i: int,
	full: i32,
) -> i32 {
	new_day, new_line, merged, reply_line := message_flags(ui, st, msgs, i)
	m := msgs[i]
	replies := m.reply_count if has_thread_line(st, m) else 0
	// The cache is for the timeline's width. A reply is laid out narrower, by
	// its indent.
	time_w := message_time_w(st, m.time)
	width := full - (REPLY_INDENT if is_indented(st, m) else 0) - message_column(ui, time_w)
	_, l, _, _ := map_entry(&st.layouts, m.id)
	shown, _, _, _ := message_text(ui, m.text)
	changing := m.kind == .File || len(m.reactions) > 0 || len(m.files) > 0
	if !changing &&
	   !l.changing &&
	   l.height > 0 &&
	   l.shown == len(shown) &&
	   l.edited == m.edited &&
	   l.flags == m.flags &&
	   l.width == full &&
	   l.merged == merged &&
	   l.new_day == new_day &&
	   l.new_line == new_line &&
	   l.replies == replies &&
	   l.reply_line == reply_line &&
	   l.pictures == ui.settings.chat_pictures &&
	   l.time_w == time_w &&
	   l.line == ui.ctx.text_height(ui.ctx.style.font) {
		return l.height
	}
	ctx := &ui.ctx
	body: i32
	kind := m.kind
	if .Deleted in m.flags {
		kind = .System // drawn as DELETED_TEXT, like a kind that has no drawing
	}
	// Measured as chat_message draws it (rich_text).
	#partial switch kind {
	case .Text:
		text := message_rich(ui, m.text)
		body = rich_height(ctx, &text, width)
	case .System:
		text := rich_plain(DELETED_TEXT if .Deleted in m.flags else system_line(ui, m))
		body = rich_height(ctx, &text, width)
	case:
		text := rich_plain(UNKNOWN_KIND_TEXT)
		body = rich_height(ctx, &text, width)
	}
	h := chat_block_height(ctx, merged, body, reply_line)
	if m.kind == .File && .Deleted not_in m.flags {
		h = file_block_height(ui, message_file(ui.view, m), width, merged, reply_line)
	}
	h += message_files_height(ui, m, width)
	h += reactions_height(ui, m, width)
	if reply_line {
		h += reply_line_height(ctx)
	}
	if replies > 0 {
		h += thread_line_height(ctx)
	}
	if new_day {
		h += usual_row_height(ctx)
	}
	if new_line {
		h += usual_row_height(ctx)
	}
	l.height, l.width, l.merged, l.new_day, l.new_line = h, full, merged, new_day, new_line
	l.edited, l.flags, l.shown = m.edited, m.flags, len(shown)
	l.replies, l.reply_line = replies, reply_line
	l.pictures = ui.settings.chat_pictures
	l.time_w = time_w
	l.line = ctx.text_height(ctx.style.font)
	l.changing = changing
	return h
}

// local_day is the local day that a message was posted, as a number that goes
// up by one each day.
local_day :: proc(ui: ^UI, st: ^UI_Timeline, m: conn.View_Message) -> i64 {
	_, l, _, _ := map_entry(&st.layouts, m.id)
	if l.day == 0 {
		dt, _ := time.time_to_datetime(time.unix(i64(m.time) / 1000, 0))
		local := chat_local_time(ui, dt)
		ordinal, _ := datetime.date_to_ordinal(local.date)
		l.day = max(i64(ordinal), 1)
	}
	return l.day
}
