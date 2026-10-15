package client

import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "common:proto"

_ :: log // only used when TIMELINE_DEBUG

// The timeline shows a conversation's messages, however long its history is,
// drawn a screenful at a time (conn/messages.odin keeps the window of messages
// that we have).
//
//   - Only what is on screen is laid out, plus one screen's height on either
//     side. Everything above and below is one empty block each. For that, every
//     message's height is worked out without laying it out, in the same way
//     that drawing it comes to (chat_block_height, wrapped_lines), and kept
//     until the width or the surrounding messages change. (An offer of a file
//     is worked out every frame, because how the transfer is going changes
//     what it says.) The heights are worked out rather than guessed: a guess
//     that is corrected once the message is drawn would move everything under
//     it.
//   - Messages are laid out at one width, which leaves room for the scrollbar
//     whether it is shown or not. Otherwise a scrollbar appearing and
//     disappearing would make the text wrap differently, making it taller or
//     shorter, which in turn would need the scrollbar again, or not.
//   - The scroll position is a message and how far into it the top of the
//     panel is, not a number of pixels. A page of older messages arriving, or
//     a picture turning up, therefore doesn't move what is on screen. At the
//     end, the timeline follows new messages.
//   - Near the top, the page before is requested, with a line saying so. Near
//     the bottom of a window that stops short of the end, the page after is
//     requested.
//   - There is a line between days, and messages from one sender within a
//     minute are drawn as one block, as before (except for a message that has
//     been edited, deleted or pinned, which has its own header to say so).
//   - Jumping to a message (from the pins): the page around it is fetched if
//     the window doesn't have it, and the message is scrolled to and
//     highlighted.
//   - Pointing at a message shows the bar with what can be done to it
//     (ui_message_bar.odin), and right-clicking it opens its menu
//     (ui_message_menu.odin).
//   - Threads (ui_threads.odin): a reply is drawn indented, with a bar beside
//     it (one bar runs down a series of replies to the same thread), and a dim
//     line above it says what it replies to (once for such a series). A root
//     with replies has a line under it saying how many. Clicking either opens
//     the thread. A reply doesn't merge with a message that isn't in its
//     thread, and no message merges with the message above it if that one has
//     its replies line.
//   - Each message is indented by a column for its sender's picture
//     (ui_avatars.odin), drawn beside its header. For a message merged under
//     another, the column is empty.
//   - The same timeline draws a thread in its window: the thread's root at the
//     top, with its replies under it. Each timeline on screen has its own
//     UI_Timeline: the conversation's is `ui.timeline`, and each thread's is
//     in its window.

@(private = "file")
TIMELINE_PANEL :: "timeline"
// The mark at the start of a reply's line.
@(private = "file")
REPLY_MARK :: "\u21aa "
// How far a reply is indented in its conversation's timeline, and where its
// bar is in that space.
@(private = "file")
REPLY_INDENT :: 14
@(private = "file")
REPLY_BAR_X :: 5
@(private = "file")
REPLY_BAR_W :: 2

// The picture beside a message's header is as tall as the header plus a line.
// avatar_column is the width of the column it is in.
avatar_size :: proc(ctx: ^mu.Context) -> i32 {
	return 2 * ctx.text_height(ctx.style.font) - 2
}
// In the compact chat, which doesn't show the pictures, there is only room for
// a dot (ui_activity.odin).
avatar_column :: proc(ui: ^UI) -> i32 {
	return avatar_size(&ui.ctx) + 8 if ui.settings.chat_pictures else COMPACT_DOT_COLUMN
}

@(private = "file")
COMPACT_DOT_COLUMN :: 14
// How far beyond the panel's edges messages are still laid out, in screens.
@(private = "file")
MARGIN_SCREENS :: 1
@(private = "file")
UNKNOWN_KIND_TEXT :: "(a message this version can't show)"

// Counts what each frame lays out, and whether any message came out at a
// different height than was worked out, to check the above (when built with
// -define:YAP_TIMELINE_DEBUG=true it is shown in the typing line).
TIMELINE_DEBUG :: #config(YAP_TIMELINE_DEBUG, false)

// Testing aid: when built with -define:YAP_ALWAYS_FOCUSED=true, the window is
// considered to have the focus whenever it is there. This is for checking
// reading where no window can get the focus (a compositor without a keyboard).
ALWAYS_FOCUSED :: #config(YAP_ALWAYS_FOCUSED, false)

UI_Timeline :: struct {
	key:          conn.Timeline_Key, // what was shown in the last frame
	// Which timeline it is: 0 for the conversation's, otherwise the thread
	// window's in ui.threads[slot - 1].
	slot:         int,
	// The roots that were requested, for the replies' lines.
	roots_asked:  map[proto.Msg_Id]bool,
	// The message at the top of the panel, and how far down it the panel's
	// top is.
	anchor:       proto.Msg_Id,
	offset:       i32,
	// Whether the end is shown and stays in view as messages come in.
	follow:       bool,
	// Whether we are going to the end, which the window may not reach yet:
	// we posted a message (set by whatever sent it, since the post may be
	// answered before a frame shows it on its way) and the newest page is
	// still coming.
	to_end:       bool,
	// The scroll position set in the last frame, to tell how much the wheel
	// or the scrollbar has moved it since.
	scroll:       i32,
	// What is known of each message.
	layouts:      map[proto.Msg_Id]Msg_Layout,
	// The height of our messages that are on their way, as in the last frame.
	outbox_h:     i32,
	// The window's first and last message when the page before or after was
	// last requested, so that it is only requested once.
	asked_older:  proto.Msg_Id,
	asked_newer:  proto.Msg_Id,
	laid_out:     int,
	mismatched:   int, // messages drawn at a different height than worked out
	// Where the unread messages began when the conversation was opened, if
	// any were: the "new messages" line goes above the first message after
	// `unread_from` (which may be 0: all of them).
	unread_line:  bool,
	unread_from:  proto.Msg_Id,
	// Whether the window reaches the conversation's first message in this
	// frame, so that the line can go above the first message shown.
	at_start:     bool,
	// The day of a thread's root in this frame (0 if it isn't here): the
	// first reply only gets a day's line if it is from another day.
	root_day:     i64,
	// Whether it was drawn in this frame, and the conversation that was last
	// reported as read, and to which session (see timeline_reading).
	shown:        bool,
	reading:      proto.Conv_Id,
	reading_to:   rawptr,
	// The conversation drawn in the last frame, focused or not, and in which
	// session (dm_open).
	open:         proto.Conv_Id,
	open_to:      rawptr,
	// A message to go to (ui_pins.odin), whether the page around it has been
	// requested, and the message that was gone to, highlighted for a while.
	jump_to:      proto.Msg_Id,
	jump_asked:   bool,
	// The conversation that jump_to is in, if it is being switched to (a
	// link's, ui_forward.odin), or 0 for this one.
	jump_conv:    proto.Conv_Id,
	// Opened with unread mentions of us: the first of them is gone to once
	// the first page is here (if it is in it).
	seek_mention: bool,
	lit_mentions: bool, // ... and they are highlighted along with the one gone to
	lit:          proto.Msg_Id,
	lit_at:       time.Tick,
}

Msg_Layout :: struct {
	// How tall it is, for the width and the neighbours that it was worked out
	// for, or 0 until it has been worked out.
	height:     i32,
	width:      i32,
	merged:     bool,
	new_day:    bool,
	new_line:   bool, // the "new messages" line is above it
	edited:     proto.Unix_Ms, // the edit time when it was worked out
	flags:      proto.Msg_Flags,
	shown:      int, // how long its text was as shown (mentions' names change)
	day:        i64, // the local day it was posted, or 0 until worked out
	// A root's replies (its line goes under it), and whether it has a reply's
	// line above it.
	replies:    int,
	reply_line: bool,
	pictures:   bool, // laid out with the pictures' column (avatar_column)
	line:       i32, // and with lines of text this tall (the chat's text size)
	// Worked out together with what is worked out afresh every frame
	// (reactions, files, an offer of a file), so it can't be reused as it is
	// once that has gone, for example when the last reaction is taken back.
	changing:   bool,
}

timeline_destroy :: proc(st: ^UI_Timeline) {
	delete(st.layouts)
	delete(st.roots_asked)
	st^ = {}
}

@(private = "file")
timeline_reset :: proc(
	st: ^UI_Timeline,
	key: conn.Timeline_Key,
	unread_line: bool,
	unread_from: proto.Msg_Id,
) {
	clear(&st.layouts)
	clear(&st.roots_asked)
	layouts, asked := st.layouts, st.roots_asked
	st^ = {
		key         = key,
		slot        = st.slot,
		roots_asked = asked,
		follow      = true,
		// Until its newest page is here: while that is loading, the window
		// doesn't reach the end yet, which would end `follow` (a browser
		// always draws a frame or more in between).
		to_end      = true,
		layouts     = layouts,
		unread_line = unread_line,
		unread_from = unread_from,
		reading     = st.reading,
		reading_to  = st.reading_to,
		jump_to     = st.jump_to,
		jump_conv   = st.jump_conv,
	}
}

// timeline lays out a timeline in the current layout cell: the conversation
// being looked at, a channel or a DM (`st` is ui.timeline), or one of its
// threads (`st` is its window's). Call with the View locked.
timeline :: proc(ui: ^UI, st: ^UI_Timeline, key: conn.Timeline_Key, readonly := false) {
	ctx := &ui.ctx
	v := ui.view
	// Messages are in the chat's text size (settings.chat_scale), and
	// everything here is measured with it.
	saved_font := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved_font
	conv := key.conv
	if st.key != key {
		// Opened with unread messages: the line goes where they begin.
		unread_line: bool
		unread_from: proto.Msg_Id
		mentions: int
		if key.root == 0 {
			unread, read, m := viewed_unread(v)
			if unread > 0 {
				unread_line, unread_from = true, read
			}
			mentions = m
		}
		timeline_reset(st, key, unread_line, unread_from)
		st.seek_mention = mentions > 0
	}
	st.shown = true
	tl: ^conn.View_Timeline
	msgs: []conn.View_Message
	if found, ok := &v.timelines[key]; ok {
		tl, msgs = found, found.messages[:]
	}
	st.at_start = tl != nil && tl.have_oldest
	pending := make([dynamic]conn.View_Pending, context.temp_allocator)
	for p in v.outbox {
		if p.conv == conv && p.root == key.root {
			append(&pending, p)
		}
	}
	panel := TIMELINE_PANEL if st.slot == 0 else fmt.tprintf("thread timeline %d", st.slot)

	cnt := mu.get_container(ctx, panel)
	pad := ctx.style.padding
	// Where the panel goes in this frame, taken here and handed to
	// begin_panel. What is worked out below has to be for this frame's size,
	// not the last one's (the window may just have been resized).
	rect := mu.layout_next(ctx)
	mu.layout_set_next(ctx, rect, false)
	view_h := rect.h
	// The width that everything is laid out at: the panel's, less the
	// scrollbar's, whether it is there or not.
	width := max(rect.w - 2 * pad - ctx.style.scrollbar_size, 100)

	// Where every message is: its top, from the top of the list (below a
	// thread's root, in a thread).
	n := len(msgs)
	tops := make([]i32, n + 1, context.temp_allocator)
	root, have_root := thread_root_message(ui, key)
	st.root_day = local_day(ui, st, root) if have_root else 0
	y := top_line_height(ctx)
	if key.root != 0 {
		y += message_height(ui, st, {root}, 0, width) if have_root else usual_row_height(ctx)
	}
	for i in 0 ..< n {
		tops[i] = y
		y += message_height(ui, st, msgs, i, width)
	}
	tops[n] = y
	total := y + st.outbox_h
	max_scroll := max(total + 2 * pad - view_h, 0)

	// Where to be: at the end, or where the anchor is, moved by however much
	// the wheel or the scrollbar moved it since.
	moved := cnt.scroll.y - st.scroll
	if st.seek_mention && tl != nil && !tl.loading && n > 0 {
		st.seek_mention = false
		for m in msgs {
			if m.id > st.unread_from &&
			   m.kind == .Text &&
			   proto.mentions_account(m.text, v.me, v.accounts[v.me].roles) {
				st.jump_to, st.jump_asked = m.id, false
				st.lit_mentions = true
				break
			}
		}
	}
	// Going to a message: once it is in the window, it becomes the anchor, a
	// little way down from the top. Until then, the page around it is
	// requested.
	if st.jump_to != 0 && (st.jump_conv == 0 || st.jump_conv == key.conv) {
		found := false
		for m in msgs {
			if m.id == st.jump_to {
				st.anchor, st.offset = m.id, -min(view_h / 4, 80)
				st.follow, st.to_end = false, false
				st.lit, st.lit_at = m.id, time.tick_now()
				st.jump_to, st.jump_asked, st.jump_conv, found = 0, false, 0, true
				moved = 0
				break
			}
		}
		if !found && !st.jump_asked && ui.session != nil && (tl == nil || !tl.loading) {
			st.jump_asked = true
			conn.push_command(&ui.session.client.commands, conn.Jump_Command{id = st.jump_to})
		}
	}
	// Following the end: what is on its way below the messages may have
	// grown since the last frame (a message with files gets its rows), which
	// this frame's end doesn't know of yet.
	following := (st.follow || st.to_end) && moved >= 0
	scroll: i32
	switch {
	case following:
		scroll = max_scroll
	case:
		scroll = cnt.scroll.y
		for m, i in msgs {
			if m.id == st.anchor {
				scroll = tops[i] + st.offset + moved
				break
			}
		}
	}
	scroll = clamp(scroll, 0, max_scroll)
	cnt.scroll.y = scroll
	cnt.content_size.y = total

	// What to lay out: what is on screen, plus a screen on either side.
	margin := MARGIN_SCREENS * max(view_h, 200)
	top, bottom := scroll - pad - margin, scroll + view_h + margin
	first := 0
	for first < n && tops[first + 1] <= top {
		first += 1
	}
	last := first
	for last < n && tops[last] < bottom {
		last += 1
	}
	// msgs[first:last] are laid out.

	mu.begin_panel(ctx, panel)
	select_begin(ui, timeline_select_panel(st.slot))
	// Everything in one column of `width`.
	mu.layout_row(ctx, {width}, 1)
	mu.layout_begin_column(ctx)
	layout := mu.get_layout(ctx)
	spacing := ctx.style.spacing

	// The line at the top: whether there is more, or this is the start. In a
	// thread, its root goes above it.
	if first == 0 {
		if key.root != 0 {
			thread_head(ui, st, root, have_root, width, readonly)
		}
		top_line(ui, st, tl, n)
	} else {
		spacer(ctx, tops[first], spacing)
	}
	// Where the last reply's bar ended, to carry it on down a series of
	// replies to the same thread.
	bar_end: i32
	bar_root: proto.Msg_Id
	for i in first ..< last {
		start := layout.next_row
		// Where the message itself is: below the lines above it, and the gap
		// before its header (not a merged message's, since one message runs on
		// into the next).
		from := timeline_message(ui, st, msgs, i, width, readonly)
		block := mu.Rect{layout.body.x, layout.body.y + from, width, layout.next_row - from}
		message_mouse(ui, st, msgs[i], block, readonly)
		if is_indented(st, msgs[i]) {
			bar_top := block.y
			if bar_root == msgs[i].thread_root && i > first {
				bar_top = bar_end
			}
			bar_bottom := layout.body.y + layout.next_row - spacing
			mu.draw_rect(
				ctx,
				{block.x + REPLY_BAR_X, bar_top, REPLY_BAR_W, bar_bottom - bar_top},
				theme.reply_bar,
			)
			bar_end, bar_root = bar_bottom, msgs[i].thread_root
		} else {
			bar_root = 0
		}
		when TIMELINE_DEBUG {
			if drawn := layout.next_row - start; drawn != tops[i + 1] - tops[i] {
				st.mismatched += 1
				log.debugf(
					"message %d: drawn %d high, worked out %d",
					msgs[i].id,
					drawn,
					tops[i + 1] - tops[i],
				)
			}
		} else {
			_ = start
		}
	}
	st.laid_out = last - first
	if last < n {
		spacer(ctx, tops[n] - tops[last], spacing)
	}

	if n == 0 && len(pending) == 0 && tl != nil && !tl.loading {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"No replies yet." if key.root != 0 else "No messages here yet.",
			label_proc,
		)
	}
	start := layout.next_row
	last_id := i64(msgs[n - 1].id) if n > 0 else 0
	// Our messages on their way, in the messages' column.
	layout.indent += avatar_column(ui)
	for p, i in pending {
		pending_message(ui, p, (last_id + 1 + i64(i)) * ITEMS_PER_MESSAGE)
	}
	layout.indent -= avatar_column(ui)
	outbox_grew := layout.next_row - start != st.outbox_h
	st.outbox_h = layout.next_row - start
	mu.layout_end_column(ctx)
	select_end(ui)
	mu.end_panel(ctx)

	// Where that left us, for the next frame: the message at the top, how
	// far into it, and whether we are at the end.
	st.scroll = cnt.scroll.y
	for i in first ..< last {
		if tops[i + 1] > cnt.scroll.y {
			st.anchor = msgs[i].id
			st.offset = cnt.scroll.y - tops[i]
			break
		}
	}
	end := max(cnt.content_size.y + 2 * pad - cnt.body.h, 0)
	st.follow =
		(cnt.scroll.y >= end - 2 || following && outbox_grew) && (tl == nil || tl.have_newest)
	if moved < 0 || (st.follow && tl != nil && !tl.loading) {
		st.to_end = false // scrolled away from the end, or already there (with its messages loaded)
	}

	// Near either end of the window, request the next page in that direction.
	if tl != nil && !tl.loading && n > 0 && ui.session != nil {
		if !tl.have_oldest && first == 0 && st.asked_older != msgs[0].id {
			st.asked_older = msgs[0].id
			conn.push_command(
				&ui.session.client.commands,
				conn.History_Command{conv = conv, root = key.root},
			)
		} else if !tl.have_newest && last == n && st.asked_newer != msgs[n - 1].id {
			st.asked_newer = msgs[n - 1].id
			conn.push_command(
				&ui.session.client.commands,
				conn.History_Command{conv = conv, root = key.root, newer = true},
			)
		}
	}
}

// spacer stands in for `height` of messages that are not laid out: a row that
// moves the next one down by that much, including the spacing.
@(private = "file")
spacer :: proc(ctx: ^mu.Context, height, spacing: i32) {
	if height <= 0 {
		return
	}
	// Not 0, which layout_row takes to mean "the usual height".
	mu.layout_row(ctx, {-1}, max(height - spacing, 1))
	mu.layout_next(ctx)
}

// A row of the usual height, and its spacing: the line at the top, and a
// day's line.
@(private = "file")
usual_row_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
}

// The line at the top is always there, empty if there is nothing to say, so
// that a change in what it says doesn't move what is under it.
@(private = "file")
top_line_height :: proc(ctx: ^mu.Context) -> i32 {
	return usual_row_height(ctx)
}

@(private = "file")
top_line :: proc(ui: ^UI, st: ^UI_Timeline, tl: ^conn.View_Timeline, n: int) {
	ctx := &ui.ctx
	thread := st.key.root != 0
	text: string
	switch {
	case tl == nil || tl.loading:
		if thread {
			text = "Loading replies..." if n == 0 else "Loading older replies..."
		} else {
			text = "Loading messages..." if n == 0 else "Loading older messages..."
		}
	case thread && tl.have_oldest && n > 0:
		rule(ui, "Replies", theme.day_line)
		return
	case tl.have_oldest && n > 0:
		text = "The start of the conversation."
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, text, label_proc)
}

// timeline_select_panel is the panel that a timeline's text is selected in.
timeline_select_panel :: proc(slot: int) -> Select_Panel {
	return .Chat if slot == 0 else Select_Panel(int(Select_Panel.Thread_1) + slot - 1)
}

// thread_root_message is a thread's root, if it is here: in its conversation's
// window, or fetched (conn.View_Root). Call with the View locked.
thread_root_message :: proc(ui: ^UI, key: conn.Timeline_Key) -> (conn.View_Message, bool) {
	v := ui.view
	if key.root == 0 {
		return {}, false
	}
	if tl, ok := v.timelines[{key.conv, 0}]; ok {
		if i, found := message_index(tl.messages[:], key.root); found {
			return tl.messages[i], true
		}
	}
	if r, ok := v.roots[key.root]; ok && r.conv == key.conv {
		return r.msg, true
	}
	return {}, false
}

// message_index is where a message is in a window, found by its id.
message_index :: proc(msgs: []conn.View_Message, id: proto.Msg_Id) -> (int, bool) {
	lo, hi := 0, len(msgs)
	for lo < hi {
		mid := (lo + hi) / 2
		if msgs[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(msgs) && msgs[lo].id == id
}

// thread_head draws a thread's root above its replies (or a line saying that
// it is on its way), as tall as the timeline works out.
@(private = "file")
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
		with_text_color(ctx, theme.dim, "Loading the message replied to...", label_proc)
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
@(private = "file")
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
		m.sender == prev.sender &&
		chat_same_minute(proto.Unix_Time(m.time / 1000), proto.Unix_Time(prev.time / 1000))
	return
}

// is_indented is whether a message is drawn as a reply: indented, with a bar
// beside it. This only applies in its conversation's timeline, not in its
// thread's.
@(private = "file")
is_indented :: proc(st: ^UI_Timeline, m: conn.View_Message) -> bool {
	return st.key.root == 0 && m.thread_root != 0
}

// has_thread_line is whether a message has its thread's line under it: a root
// with replies, in its conversation's timeline.
@(private = "file")
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

// Each message has up to this many items to select from (ui_select.odin): its
// header and text, or a file's header, name and state.
ITEMS_PER_MESSAGE :: 4

// pending_message draws a message of ours that is on its way.
pending_message :: proc(ui: ^UI, p: conn.View_Pending, item: i64) {
	text: Rich
	#partial switch p.kind {
	case .File:
		text = rich_plain(fmt.tprintf("the file %s", p.text))
	case:
		shown, spans, emoji := conn.text_display(
			p.text,
			ui.view.accounts,
			ui.view.roles[:],
			ui.view.me,
			ui.view.emoji.names[:],
		)
		text = rich_make(shown, spans, emoji, nil, false)
	}
	status := "sending files..." if p.uploading else "sending..."
	chat_message(ui, status, theme.dim, &text, theme.dim, false, item)
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
			return dm.unread, dm.read, 0
		}
	}
	return
}

// message_file is what is known about a file that a message offers: how its
// transfer is going, if there is one here.
@(private = "file")
message_file :: proc(v: ^conn.View, m: conn.View_Message) -> conn.View_File {
	if f, ok := v.files[m.id]; ok {
		return f
	}
	return {name = m.text, size = m.file_size, outgoing = m.sender == v.me, state = .Unknown}
}

// message_height is how far drawing msgs[i] at `width` moves the layout down
// (timeline_message).
@(private = "file")
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
	width := full - (REPLY_INDENT if is_indented(st, m) else 0) - avatar_column(ui)
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
	h += message_files_height(ui, m)
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
	l.line = ctx.text_height(ctx.style.font)
	l.changing = changing
	return h
}

// local_day is the local day that a message was posted, as a number that goes
// up by one each day.
@(private = "file")
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

// timeline_message draws msgs[i] and says where in the layout the message
// itself starts (after a day's line, the "new messages" line, and the gap
// above a header).
@(private = "file")
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
		rule(ui, "New messages", theme.new_line)
	}
	// A reply is indented: everything of it from here on.
	indent: i32 = REPLY_INDENT if is_indented(st, m) else 0
	column := avatar_column(ui)
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
	stamp := "" if merged else chat_time(ui, seconds)
	// Their name opens their menu, unless it is ours.
	ui.header_sender = 0
	if !merged && m.sender != v.me {
		ui.header_sender = m.sender
		ui.header_name = {len(stamp) + 2, len(stamp) + 2 + len(name)}
	}
	defer ui.header_sender = 0
	// Room for a bot's tag after the name, which selectable_header draws.
	bot_room := ""
	ui.header_bot = 0
	if !merged && is_bot(v, m.sender) {
		ui.header_bot = len(stamp) + 2 + len(name)
		bot_room = header_room(ctx, bot_tag_width(ctx))
	}
	defer ui.header_bot = 0
	header :=
		"" if merged else fmt.tprintf("%s  %s%s%s%s%s", stamp, name, bot_room, "  (edited)" if m.edited != 0 && .Deleted not_in m.flags else "", "  - pinned" if .Pinned in m.flags else "", forward_note(ui, m))
	header_color := author_color(v, m.sender)
	item := i64(m.id) * ITEMS_PER_MESSAGE
	if !merged {
		// The picture, beside the header (which comes after the gap), or in
		// the compact chat, the dot beside it.
		layout := mu.get_layout(ctx)
		y := layout.body.y + layout.next_row + (MERGED_GAP if tight else ctx.style.spacing)
		if ui.settings.chat_pictures {
			size := avatar_size(ctx)
			pic := mu.Rect{layout.body.x + indent, y, size, size}
			avatar(ui, m.sender, pic)
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
				{layout.body.x + indent, y, COMPACT_DOT_COLUMN, ctx.text_height(ctx.style.font)},
			)
		}
	}
	if .Deleted in m.flags {
		text := rich_plain(DELETED_TEXT)
		chat_message(ui, header, header_color, &text, theme.dim, merged, item, tight)
		return from
	}
	#partial switch m.kind {
	case .File:
		file_message(ui, header, header_color, m.id, message_file(v, m), merged, item, tight)
	case .Text:
		text := message_rich(ui, m.text)
		chat_message(ui, header, header_color, &text, ctx.style.colors[.TEXT], merged, item, tight)
		message_files(ui, st.key.conv, m)
	case .System:
		text := rich_plain(system_line(ui, m))
		chat_message(ui, header, header_color, &text, theme.dim, merged, item, tight)
	case:
		text := rich_plain(UNKNOWN_KIND_TEXT)
		chat_message(ui, header, header_color, &text, theme.dim, merged, item, tight)
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
			shown, _ := conn.mentions_display(root.text, v.accounts, v.roles[:], v.me)
			said = conn.markdown_plain(shown)
		}
		said = conn.one_line(said)
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
	if thread_link(ui, text, r, theme.dim) {
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
	if thread_link(ui, text, r, theme.chat_name) {
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
	mu.draw_text(ctx, font, text, {r.x, r.y}, theme.link_hover if over else color)
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

// A message's reactions are a row of chips under it, each with its emoji and
// how many reacted with it, with ours highlighted. They wrap onto more rows
// when the width runs out. Clicking one adds or removes our reaction.
// reactions_height has to agree with reaction_chips.
@(private = "file")
Chip :: struct {
	r:     conn.Reaction,
	text:  string, // the emoji as shown, followed by the count
	icons: []conn.Emoji_Span, // the server's emoji in it
	w:     i32,
}

// The gap above the chips, and their height (logical pixels).
@(private = "file")
CHIPS_GAP :: 3
@(private = "file")
chip_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.text_height(ctx.style.font) + 6
}

// reaction_rows lays a message's chips out in rows at `width`.
@(private = "file")
reaction_rows :: proc(ui: ^UI, m: conn.View_Message, width: i32) -> [][dynamic]Chip {
	ctx := &ui.ctx
	rows := make([dynamic][dynamic]Chip, context.temp_allocator)
	x := width + 1
	for r in m.reactions {
		code := fmt.tprintf("%s %d", r.emoji, r.count)
		shown, _, icons := conn.text_display(
			code,
			map[proto.Account_Id]conn.View_Account{},
			nil,
			0,
			ui.view.emoji.names[:],
		)
		w := ctx.text_width(ctx.style.font, shown) + 12
		if x + w > width && x > 0 {
			append(&rows, make([dynamic]Chip, context.temp_allocator))
			x = 0
		}
		append(&rows[len(rows) - 1], Chip{r, shown, icons, w})
		x += w + ctx.style.spacing
	}
	return rows[:]
}

@(private = "file")
reactions_height :: proc(ui: ^UI, m: conn.View_Message, width: i32) -> i32 {
	if len(m.reactions) == 0 || .Deleted in m.flags {
		return 0
	}
	ctx := &ui.ctx
	rows := i32(len(reaction_rows(ui, m, width)))
	return CHIPS_GAP + ctx.style.spacing + rows * (chip_height(ctx) + ctx.style.spacing)
}

@(private = "file")
reaction_chips :: proc(ui: ^UI, m: conn.View_Message, width: i32, readonly := false) {
	if len(m.reactions) == 0 || .Deleted in m.flags {
		return
	}
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, CHIPS_GAP)
	mu.layout_next(ctx)
	h := chip_height(ctx)
	mu.push_id(ctx, uintptr(m.id))
	defer mu.pop_id(ctx)
	for row, ri in reaction_rows(ui, m, width) {
		widths := make([]i32, len(row), context.temp_allocator)
		for c, i in row {
			widths[i] = c.w
		}
		mu.layout_row(ctx, widths, h)
		for c, i in row {
			mu.push_id(ctx, uintptr(ri * proto.MAX_REACTIONS + i))
			id := mu.get_id(ctx, "chip")
			rect := mu.layout_next(ctx)
			mu.update_control(ctx, id, rect)
			background := theme.track
			switch {
			case c.r.me:
				background = theme.highlight
			case ctx.hover_id == id:
				background = ctx.style.colors[.BUTTON_HOVER]
			}
			if ctx.hover_id == id && c.r.me {
				background = theme.highlight_more
			}
			mu.draw_rect(ctx, rect, background)
			font := ctx.style.font
			pos := mu.Vec2{rect.x + 6, rect.y + (rect.h - ctx.text_height(font)) / 2}
			mu.draw_text(ctx, font, c.text, pos, ctx.style.colors[.TEXT])
			draw_chip_emoji(ui, c, pos)
			if ctx.hover_id == id {
				reactors_hint(ui, m.id, c.r, rect)
			}
			if !readonly && ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} {
				send_reaction(ui, m.id, c.r.emoji, !c.r.me)
			}
			mu.pop_id(ctx)
		}
	}
}

// Who reacted, as last requested (reactors_hint): not requested again while
// it is the same message, emoji and count.
Reactors_Asked :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned
	count: int,
}

// How many names a reaction's hint lists, and how many per line.
@(private = "file")
REACTORS_SHOWN :: 15
@(private = "file")
REACTORS_PER_LINE :: 5

// reactors_hint is the hint above a reaction: the emoji's :name:, and who
// reacted with it ("you" for us), the first REACTORS_SHOWN and how many more.
// Who it was is requested from the server the first time the pointer is on
// it, and again when the count has changed.
@(private = "file")
reactors_hint :: proc(ui: ^UI, id: proto.Msg_Id, r: conn.Reaction, rect: mu.Rect) {
	v := ui.view
	asked := &ui.reactors_asked
	name := r.emoji
	if !strings.has_prefix(name, ":") {
		first, _ := utf8.decode_rune_in_string(r.emoji)
		if index, ok := proto.emoji_index(first); ok {
			name = fmt.tprintf(":%s:", proto.emoji_name(proto.EMOJI[index]))
		}
	}
	have := v.reactors.id == id && v.reactors.emoji == r.emoji && v.reactors.total == r.count
	hint_emoji_of(ui, r.emoji)
	if !have &&
	   (asked.id != id || asked.emoji != r.emoji || asked.count != r.count) &&
	   ui.session != nil {
		delete(asked.emoji)
		asked^ = {id, strings.clone(r.emoji), r.count}
		conn.push_command(
			&ui.session.client.commands,
			conn.Reactors_Command{id = id, emoji = strings.clone(r.emoji)},
		)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name)
	if !have {
		strings.write_string(&b, "\n...")
		ui.hint, ui.hint_of = strings.to_string(b), rect
		return
	}
	shown := min(len(v.reactors.accounts), REACTORS_SHOWN)
	for account, i in v.reactors.accounts[:shown] {
		strings.write_string(&b, "\n" if i % REACTORS_PER_LINE == 0 else ", ")
		switch {
		case account == v.me:
			strings.write_string(&b, "you")
		case account in v.accounts:
			strings.write_string(&b, v.accounts[account].display)
		case:
			strings.write_string(&b, "someone")
		}
	}
	if more := v.reactors.total - shown; more > 0 {
		fmt.sbprintf(&b, "\nand %d more", more)
	}
	ui.hint, ui.hint_of = strings.to_string(b), rect
}

// draw_chip_emoji draws the server's emoji over their placeholders in a chip's
// text, drawn at `pos`.
@(private = "file")
draw_chip_emoji :: proc(ui: ^UI, c: Chip, pos: mu.Vec2) {
	ctx := &ui.ctx
	for e in c.icons {
		icon, ok := custom_emoji_icon(ui, e.index)
		if !ok {
			continue
		}
		x := pos.x + ctx.text_width(ctx.style.font, c.text[:e.start])
		size, advance := custom_emoji_size(ctx)
		gap := (advance - size) / 2
		y := pos.y + (ctx.text_height(ctx.style.font) - size) / 2
		mu.draw_icon(ctx, icon, {x + gap, y, size, size}, {255, 255, 255, 255})
	}
}

// system_line is what a system message says (so far, a call's line).
@(private = "file")
system_line :: proc(ui: ^UI, m: conn.View_Message) -> string {
	v := ui.view
	name := "someone"
	if acc, ok := v.accounts[m.sender]; ok {
		name = acc.display
	}
	return fmt.tprintf(
		"\U0001F4DE %s",
		conn.system_text(m.system, m.system_arg, name, m.sender == v.me),
	)
}

// What is left of a deleted message.
@(private = "file")
DELETED_TEXT :: "message deleted"

// message_mouse is what the pointer does to a message laid out in `block`:
// pointing at it shows the message's bar over it, and a right click opens its
// menu. The message that was jumped to is highlighted for a while, and when it
// was jumped to as the first unread mention of us, the others are
// highlighted too.
@(private = "file")
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
			ui_redraw_in(ui, ANIMATION_FRAME)
			mu.draw_rect(ctx, block, {255, 220, 120, u8(50 * fade)})
		} else {
			st.lit, st.lit_mentions = 0, false
		}
	}
	if !readonly {
		message_bar_track(ui, st.key.conv, st.slot, m, block)
		if .RIGHT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, block) {
			open_message_menu(ui, m, st.slot)
		}
	}
}

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
	rule(ui, text, theme.day_line)
}

// rule is a line across the timeline with `text` in the middle of it, in a row
// of the usual height.
@(private = "file")
rule :: proc(ui: ^UI, text: string, color: mu.Color) {
	ctx := &ui.ctx
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

// timeline_reading tells the network side which conversation is being read,
// when that changes: the one whose timeline was drawn in this frame and is at
// its newest message, in a window that has the focus. Call after the frame.
timeline_reading :: proc(ui: ^UI, focused: bool) {
	st := &ui.timeline
	reading: proto.Conv_Id
	if st.shown && st.follow && focused {
		reading = st.key.conv
	}
	st.open = st.key.conv if st.shown else 0
	st.open_to = rawptr(ui.session)
	st.shown = false
	// A new session doesn't know of anything being read.
	session := rawptr(ui.session)
	if session == nil {
		st.reading, st.reading_to = 0, nil
		return
	}
	if reading != st.reading || session != st.reading_to {
		conn.push_command(&ui.session.client.commands, conn.Reading_Command{conv = reading})
		st.reading, st.reading_to = reading, session
	}
}
