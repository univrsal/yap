package ui

import log "common:wlog"
import "core:fmt"
import "core:time"
import "core:time/datetime"
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
//     (ui/message_bar.odin), and right-clicking it opens its menu
//     (ui/message_menu.odin).
//   - Threads (ui/threads.odin): a reply is drawn indented, with a bar beside
//     it (one bar runs down a series of replies to the same thread), and a dim
//     line above it says what it replies to (once for such a series). A root
//     with replies has a line under it saying how many. Clicking either opens
//     the thread. A reply doesn't merge with a message that isn't in its
//     thread, and no message merges with the message above it if that one has
//     its replies line.
//   - Each message is indented by a column for its sender's picture
//     (ui/avatars.odin), drawn beside its header. For a message merged under
//     another, the column is empty.
//   - The same timeline draws a thread in its window: the thread's root at the
//     top, with its replies under it. Each timeline on screen has its own
//     UI_Timeline: the conversation's is `ui.timeline`, and each thread's is
//     in its window.

@(private = "file")
TIMELINE_PANEL :: "timeline"
// The mark at the start of a reply's line.
REPLY_MARK :: "\u21aa "
// How far a reply is indented in its conversation's timeline, and where its
// bar is in that space.
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
// a dot (ui/activity.odin).
avatar_column :: proc(ui: ^UI) -> i32 {
	return avatar_size(&ui.ctx) + 8 if ui.settings.chat_pictures else COMPACT_DOT_COLUMN
}

// In the compact chat, a message's time (chat_time) comes first, in a column of
// its own before the dot's, right-aligned in it. The column is as wide as the
// longest time the locale writes for the message: with `dates`, an older day's
// (with the date), otherwise today's (the time of day). So today's messages
// line up with each other, and older ones with each other, without today's
// leaving room for a date they don't have. With the pictures, the time goes in
// the header after the name instead, and there is no column for it.
time_column :: proc(ui: ^UI, dates: bool) -> i32 {
	if ui.settings.chat_pictures {
		return 0
	}
	ctx := &ui.ctx
	longest := datetime.DateTime {
		date = {year = 2088, month = 12, day = 28},
		time = {hour = 22, minute = 58},
	}
	text := date_time_text(ui.date_style, longest, !dates)
	return ctx.text_width(ctx.style.font, text) + TIME_GAP
}
TIME_GAP :: 10

// message_time_w is the width of a message's times' column: posted at `ms`
// (Unix milliseconds), before today or not. Call after timeline has worked
// out this frame's widths.
message_time_w :: proc(st: ^UI_Timeline, ms: proto.Unix_Ms) -> i32 {
	return st.time_w_dated if i64(ms) / 1000 < st.midnight else st.time_w_today
}

// message_column is how far in from the timeline's edge (or a reply's
// indent) a message's header and text start: past its time and the picture.
message_column :: proc(ui: ^UI, time_w: i32) -> i32 {
	return time_w + avatar_column(ui)
}

// local_midnight is when today began in the local time zone, in Unix
// seconds: what chat_time writes without a date from.
@(private = "file")
local_midnight :: proc(ui: ^UI) -> i64 {
	now := time.now()
	dt, _ := time.time_to_datetime(now)
	local := chat_local_time(ui, dt)
	since := i64(local.hour) * 3600 + i64(local.minute) * 60 + i64(local.second)
	return time.to_unix_seconds(now) - since
}

COMPACT_DOT_COLUMN :: 14
// How far beyond the panel's edges messages are still laid out, in screens.
@(private = "file")
MARGIN_SCREENS :: 1
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
	// A message to go to (ui/pins.odin), whether the page around it has been
	// requested, and the message that was gone to, highlighted for a while.
	jump_to:      proto.Msg_Id,
	jump_asked:   bool,
	// The conversation that jump_to is in, if it is being switched to (a
	// link's, ui/forward.odin), or 0 for this one.
	jump_conv:    proto.Conv_Id,
	// Opened with unread mentions of us: the first of them is gone to once
	// the first page is here (if it is in it).
	seek_mention: bool,
	lit_mentions: bool, // ... and they are highlighted along with the one gone to
	lit:          proto.Msg_Id,
	lit_at:       time.Tick,
	// In this frame: when today began (local_midnight), and the width of the
	// times' column for today's messages and older ones (time_column).
	midnight:     i64,
	time_w_today: i32,
	time_w_dated: i32,
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
	time_w:     i32, // and with the times' column this wide (time_column)
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
	// On a phone, closer together than the controls around them.
	saved_padding, saved_spacing := ctx.style.padding, ctx.style.spacing
	if ui.compact {
		ctx.style.padding, ctx.style.spacing = COMPACT_MESSAGE_PADDING, COMPACT_MESSAGE_SPACING
	}
	defer ctx.style.padding, ctx.style.spacing = saved_padding, saved_spacing
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
	st.midnight = local_midnight(ui)
	st.time_w_today, st.time_w_dated = time_column(ui, false), time_column(ui, true)
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
			command(ui, conn.Jump_Command{id = st.jump_to})
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

	mu.begin_panel(ctx, panel, {.NO_FRAME})
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
		dim_label(ctx, "No replies yet." if key.root != 0 else "No messages here yet.")
	}
	start := layout.next_row
	last_id := i64(msgs[n - 1].id) if n > 0 else 0
	// Our messages on their way, in the messages' column.
	// (They are today's.)
	layout.indent += message_column(ui, st.time_w_today)
	for p, i in pending {
		pending_message(ui, p, (last_id + 1 + i64(i)) * ITEMS_PER_MESSAGE)
	}
	layout.indent -= message_column(ui, st.time_w_today)
	outbox_grew := layout.next_row - start != st.outbox_h
	st.outbox_h = layout.next_row - start
	mu.layout_end_column(ctx)
	select_end(ui)
	mu.end_panel(ctx)

	// How far the panel moved itself in this frame: its scrollbar, or a
	// selection dragged past its edge (the wheel's is `moved`, next frame).
	dragged := cnt.scroll.y - scroll

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
	// Moving up, by however little, stops following the end: a pixel's drag
	// (as little as a slow drag of the scrollbar moves a short timeline) is
	// close enough to the end to count as there, and the next frame would go
	// back to it. It is followed again once the end is gone back to.
	up := moved < 0 || dragged < 0
	near_end := cnt.scroll.y >= end - 2
	st.follow =
		!up &&
		(near_end && (following || moved > 0 || dragged > 0 || cnt.scroll.y >= end) ||
				following && outbox_grew) &&
		(tl == nil || tl.have_newest)
	if up || (st.follow && tl != nil && !tl.loading) {
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
		// Messages, or older ones above these, on their way.
		spinner_row(ui)
		return
	case thread && tl.have_oldest && n > 0:
		rule(ui, "Replies", theme.day_line)
		return
	case tl.have_oldest && n > 0:
		text = "The start of the conversation."
	}
	mu.layout_row(ctx, {-1})
	dim_label(ctx, text)
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
		command(ui, conn.Reading_Command{conv = reading})
		st.reading, st.reading_to = reading, session
	}
}
