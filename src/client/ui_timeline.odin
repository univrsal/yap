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

/*
The timeline: a conversation's messages, as long as its history is,
drawn a screenful at a time (conn/messages.odin keeps the window of them
we have).

  - Only what's on screen is laid out, and a screen's height either side;
    what's above and below is one empty block each. For that, every
    message's height is worked out without laying it out, the same way
    drawing it comes to (chat_block_height, wrapped_lines), and kept until
    the width or what's around it changes. (An offer of a file is worked
    out every frame: how it's going changes what it says.) Worked out, not guessed: a
    guess put right once the message is drawn would move everything
    under it.
  - Messages are laid out at one width, leaving room for the scrollbar
    whether it's there or not: a scrollbar coming and going would
    otherwise make the text wrap differently, and so be taller or
    shorter, and so want the scrollbar, or not.
  - The scroll position is a message and how far into it the top of the
    panel is, not a number of pixels: a page of older messages arriving,
    or a picture turning up, doesn't move what's on screen. At the end it
    follows new messages.
  - Near the top, the page before is asked for, with a line saying so;
    near the bottom of a window that stops short of the end, the one
    after.
  - A line between days, and messages from one sender within a minute
    drawn as one block, as before (but for one that's been edited,
    deleted or pinned, which has its header to say so).
  - Jumping to a message (from the pins): the page around it is fetched
    if the window doesn't have it, and it's scrolled to and lit up.
  - The pointer on a message shows the bar of what can be done to it
    (ui_message_bar.odin), and right-clicking it opens its menu
    (ui_message_menu.odin).
  - Threads (ui_threads.odin): a reply is drawn indented, with a bar
    beside it (one bar down a run of replies to the same thread), and a
    dim line over it saying what it replies to (once for such a run),
    and a root with replies a line under it saying how many; clicking
    either opens the thread. A reply doesn't merge with a message that
    isn't of its thread, nor anything with the message over it when
    that has its replies' line.
  - Each message is indented by a column for its sender's picture
    (ui_avatars.odin), drawn beside its header; a message merged under
    another has the column empty.
  - The same timeline draws a thread, in its window: the thread's root
    at the top, its replies under it. Each timeline on screen has its own
    UI_Timeline: the conversation's is `ui.timeline`, each thread's its
    window's.
*/

@(private = "file")
TIMELINE_PANEL :: "timeline"
// The mark at the start of a reply's line.
@(private = "file")
REPLY_MARK :: "\u21aa "
// How far a reply is indented in its conversation's timeline, and the
// bar in that room.
@(private = "file")
REPLY_INDENT :: 14
@(private = "file")
REPLY_BAR_X :: 5
@(private = "file")
REPLY_BAR_W :: 2
@(private = "file")
REPLY_BAR_COLOR :: mu.Color{85, 105, 135, 255}

// The picture beside a message's header: as tall as the header and a
// line, and the column it's in.
avatar_size :: proc(ctx: ^mu.Context) -> i32 {
	return 2 * ctx.text_height(ctx.style.font) - 2
}
// In the compact chat, which doesn't show the pictures, only room for
// a dot (ui_activity.odin).
avatar_column :: proc(ui: ^UI) -> i32 {
	return avatar_size(&ui.ctx) + 8 if ui.settings.chat_pictures else COMPACT_DOT_COLUMN
}

@(private = "file")
COMPACT_DOT_COLUMN :: 14
// How far beyond the panel's edges messages are still laid out, in
// screens.
@(private = "file")
MARGIN_SCREENS :: 1
@(private = "file")
DAY_LINE_COLOR :: mu.Color{110, 110, 110, 255}
@(private = "file")
NEW_LINE_COLOR :: mu.Color{220, 90, 90, 255}
@(private = "file")
UNKNOWN_KIND_TEXT :: "(a message this version can't show)"

// Counting what each frame lays out, and whether any message came out
// another height than worked out, for checking the above (built with
// -define:YAP_TIMELINE_DEBUG=true it's shown in the typing line).
TIMELINE_DEBUG :: #config(YAP_TIMELINE_DEBUG, false)

// Testing aid: built with -define:YAP_ALWAYS_FOCUSED=true, the window is
// taken to have the focus whenever it's there, for checking reading where
// no window can get it (a compositor without a keyboard).
ALWAYS_FOCUSED :: #config(YAP_ALWAYS_FOCUSED, false)

UI_Timeline :: struct {
	key:          conn.Timeline_Key, // what was shown last frame
	// Which timeline it is: 0 the conversation's, else the thread
	// window's in ui.threads[slot - 1].
	slot:         int,
	// The roots asked for, for replies' lines.
	roots_asked:  map[proto.Msg_Id]bool,
	// The message at the top of the panel, and how far down it the
	// panel's top is.
	anchor:       proto.Msg_Id,
	offset:       i32,
	// Showing the end, and staying there as messages come.
	follow:       bool,
	// Going to the end, which the window may not reach yet: we've posted
	// (set by whatever sent it, since the post may be answered before a
	// frame shows it on its way), and the newest page is coming.
	to_end:       bool,
	// The scroll set last frame, to tell by how much the wheel or the
	// scrollbar has moved it since.
	scroll:       i32,
	// What's known of each message.
	layouts:      map[proto.Msg_Id]Msg_Layout,
	// The messages of ours on their way, as tall as they were last frame.
	outbox_h:     i32,
	// The window's first and last message when the page before or after
	// it was last asked for, so it's asked for once.
	asked_older:  proto.Msg_Id,
	asked_newer:  proto.Msg_Id,
	laid_out:     int,
	mismatched:   int, // messages drawn at another height than worked out
	// Where the unread messages began when the conversation was opened,
	// if any were: the "new messages" line goes above the first message
	// after `unread_from` (which may be 0: all of them).
	unread_line:  bool,
	unread_from:  proto.Msg_Id,
	// The window reaches the conversation's first message this frame, so
	// the line can go above the first message shown.
	at_start:     bool,
	// A thread's root's day this frame (0 if it isn't here): the first
	// reply has a day's line only for another day.
	root_day:     i64,
	// Drawn this frame; and the conversation last said to be read, and to
	// which session (see timeline_reading).
	shown:        bool,
	reading:      proto.Conv_Id,
	reading_to:   rawptr,
	// A message to go to (ui_pins.odin), and whether the page around it
	// has been asked for; and the one gone to, lit up for a while.
	jump_to:      proto.Msg_Id,
	jump_asked:   bool,
	// The conversation jump_to is in, if it's being switched to (a
	// link's, ui_forward.odin); 0 for this one.
	jump_conv:    proto.Conv_Id,
	// Opened with unread mentions of us: the first of them is gone to,
	// once the first page is here (if it's in it).
	seek_mention: bool,
	lit_mentions: bool, // ... and they're lit up with the one gone to
	lit:          proto.Msg_Id,
	lit_at:       time.Tick,
}

Msg_Layout :: struct {
	// How tall it is, for the width and the neighbours it was worked out
	// for; 0 until it has been.
	height:     i32,
	width:      i32,
	merged:     bool,
	new_day:    bool,
	new_line:   bool, // the "new messages" line is above it
	edited:     proto.Unix_Ms, // what it said when it was worked out
	flags:      proto.Msg_Flags,
	shown:      int, // how long its text was as shown (mentions' names change)
	day:        i64, // the local day it was posted, 0 until worked out
	// A root's replies (its line under it), and whether it has a reply's
	// line over it.
	replies:    int,
	reply_line: bool,
	pictures:   bool, // laid out with the pictures' column (avatar_column)
	line:       i32, // and lines of text this tall (the chat's text size)
	// Worked out with what's worked out afresh every frame (reactions,
	// files, an offer of a file), so not to be taken as it is once that
	// has gone: the last reaction taken back, say.
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
		// Until its newest page is here: while that's loading the window
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

/*
timeline lays out a timeline in the current layout cell: the
conversation being looked at, a channel or a DM (`st` is ui.timeline),
or one of its threads (`st` is its window's). Call with the View locked.
*/
timeline :: proc(ui: ^UI, st: ^UI_Timeline, key: conn.Timeline_Key) {
	ctx := &ui.ctx
	v := &ui.view
	// Messages are in the chat's text size (settings.chat_scale), and
	// everything here is measured with it.
	saved_font := ctx.style.font
	ctx.style.font = render.CHAT_FONT
	defer ctx.style.font = saved_font
	conv := key.conv
	if st.key != key {
		// Opened with messages unread: the line goes where they begin.
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
	// Where the panel goes this frame, taken here and handed to
	// begin_panel: what's worked out below has to be for this frame's
	// size, not the last one's (the window may just have been resized).
	rect := mu.layout_next(ctx)
	mu.layout_set_next(ctx, rect, false)
	view_h := rect.h
	// The width everything is laid out at: the panel's, less the
	// scrollbar's, there or not.
	width := max(rect.w - 2 * pad - ctx.style.scrollbar_size, 100)

	// Where every message is: its top, from the top of the list (under
	// a thread's root, in a thread).
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

	// Where to be: at the end, or where the anchor is, moved by however
	// much the wheel or the scrollbar moved it since.
	moved := cnt.scroll.y - st.scroll
	if st.seek_mention && tl != nil && !tl.loading && n > 0 {
		st.seek_mention = false
		for m in msgs {
			if m.id > st.unread_from && m.kind == .Text && proto.mentions_account(m.text, v.me) {
				st.jump_to, st.jump_asked = m.id, false
				st.lit_mentions = true
				break
			}
		}
	}
	// Going to a message: once it's in the window, it's the anchor, a
	// little way down from the top; until then, the page around it is
	// asked for.
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
	// Following the end: what's on its way below the messages may have
	// grown since last frame (a message with files gets its rows), which
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

	// What to lay out: what's on screen, and a screen either side.
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

	// The line at the top: whether there's more, or this is the start.
	// In a thread, its root over it.
	if first == 0 {
		if key.root != 0 {
			thread_head(ui, st, root, have_root, width)
		}
		top_line(ui, st, tl, n)
	} else {
		spacer(ctx, tops[first], spacing)
	}
	// Where the last reply's bar ended, to carry it on down a run of
	// replies to the same thread.
	bar_end: i32
	bar_root: proto.Msg_Id
	for i in first ..< last {
		start := layout.next_row
		// Where the message itself is: below the lines over it, and the
		// gap before its header (not a merged one's: one message runs on
		// into the next).
		from := timeline_message(ui, st, msgs, i, width)
		block := mu.Rect{layout.body.x, layout.body.y + from, width, layout.next_row - from}
		message_mouse(ui, st, msgs[i], block)
		if is_indented(st, msgs[i]) {
			bar_top := block.y
			if bar_root == msgs[i].thread_root && i > first {
				bar_top = bar_end
			}
			bar_bottom := layout.body.y + layout.next_row - spacing
			mu.draw_rect(
				ctx,
				{block.x + REPLY_BAR_X, bar_top, REPLY_BAR_W, bar_bottom - bar_top},
				REPLY_BAR_COLOR,
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
			CHAT_DIM_COLOR,
			"No replies yet." if key.root != 0 else "No messages here yet.",
			label_proc,
		)
	}
	start := layout.next_row
	last_id := i64(msgs[n - 1].id) if n > 0 else 0
	// Ours on their way, in the messages' column.
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

	// Where that left us, for the next frame: the message at the top and
	// how far into it, and whether we're at the end.
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
		st.to_end = false // scrolled away from it, or there (with what's there in)
	}

	// Near either end of the window, the next page that way.
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

// spacer stands in for `height` of messages not laid out: a row that
// moves the next one down by that much, spacing and all.
@(private = "file")
spacer :: proc(ctx: ^mu.Context, height, spacing: i32) {
	if height <= 0 {
		return
	}
	// Not 0, which layout_row takes as "the usual height".
	mu.layout_row(ctx, {-1}, max(height - spacing, 1))
	mu.layout_next(ctx)
}

// A row of the usual height, and its spacing: the line at the top, and a
// day's line.
@(private = "file")
usual_row_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
}

// The line at the top is always there, empty if there's nothing to say,
// so that what it says changing doesn't move what's under it.
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
		rule(ui, "Replies", DAY_LINE_COLOR)
		return
	case tl.have_oldest && n > 0:
		text = "The start of the conversation."
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, CHAT_DIM_COLOR, text, label_proc)
}

// timeline_select_panel is the panel a timeline's text is selected in.
timeline_select_panel :: proc(slot: int) -> Select_Panel {
	return .Chat if slot == 0 else Select_Panel(int(Select_Panel.Thread_1) + slot - 1)
}

/*
thread_root_message is a thread's root, if it's here: in its
conversation's window, or fetched (conn.View_Root). Call with the View
locked.
*/
thread_root_message :: proc(ui: ^UI, key: conn.Timeline_Key) -> (conn.View_Message, bool) {
	v := &ui.view
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

// message_index is where a message is in a window, by its id.
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

// thread_head draws a thread's root, over its replies (or a line saying
// it's on its way): as tall as the timeline works out.
@(private = "file")
thread_head :: proc(ui: ^UI, st: ^UI_Timeline, root: conn.View_Message, have: bool, width: i32) {
	ctx := &ui.ctx
	if !have {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, CHAT_DIM_COLOR, "Loading the message replied to...", label_proc)
		return
	}
	layout := mu.get_layout(ctx)
	from := timeline_message(ui, st, {root}, 0, width)
	message_mouse(
		ui,
		st,
		root,
		{layout.body.x, layout.body.y + from, width, layout.next_row - from},
	)
}

// message_flags says whether a message starts a day (and gets the day's
// line), whether the unread messages start with it (and it gets the
// "new messages" line), and whether it's drawn as part of the one before.
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
		// Above the first message shown only if it's the conversation's
		// first: else the line's place may be further up, not loaded yet.
		return true,
			st.unread_line && st.at_start && msgs[0].id > st.unread_from,
			false,
			!in_thread && msgs[0].thread_root != 0
	}
	m, prev := msgs[i], msgs[i - 1]
	from := st.unread_from
	new_day = local_day(ui, st, m) != local_day(ui, st, prev)
	new_line = st.unread_line && prev.id <= from && m.id > from
	// Once for replies to the same thread in a row, and never merged
	// with anything but them.
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

// is_indented is whether a message is drawn as a reply: indented, with
// a bar beside it. In its conversation's timeline, not in its thread's.
@(private = "file")
is_indented :: proc(st: ^UI_Timeline, m: conn.View_Message) -> bool {
	return st.key.root == 0 && m.thread_root != 0
}

// has_thread_line is whether a message has its thread's line under it:
// a root with replies, in its conversation's timeline.
@(private = "file")
has_thread_line :: proc(st: ^UI_Timeline, m: conn.View_Message) -> bool {
	return st.key.root == 0 && .Has_Thread in m.flags && m.reply_count > 0
}

// The heights of a reply's line (and the gap over it) and of a root's
// thread line.
@(private = "file")
reply_line_height :: proc(ctx: ^mu.Context) -> i32 {
	return 1 + ctx.text_height(ctx.style.font) + 2 * ctx.style.spacing
}
@(private = "file")
thread_line_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.text_height(ctx.style.font) + ctx.style.spacing
}

// Each message is up to this many items to select from (ui_select.odin):
// its header and text, or a file's header, name and state.
ITEMS_PER_MESSAGE :: 4

// pending_message draws a message of ours on its way.
pending_message :: proc(ui: ^UI, p: conn.View_Pending, item: i64) {
	text: Rich
	#partial switch p.kind {
	case .Image:
		text = rich_plain(fmt.tprintf("a picture, %dx%d", p.width, p.height))
	case .File:
		text = rich_plain(fmt.tprintf("the file %s", p.text))
	case:
		shown, spans, emoji := conn.text_display(
			p.text,
			ui.view.accounts,
			ui.view.me,
			ui.view.emoji.names[:],
		)
		text = rich_make(shown, spans, emoji, nil, false)
	}
	status := "sending files..." if p.uploading else "sending..."
	chat_message(ui, status, CHAT_DIM_COLOR, &text, CHAT_DIM_COLOR, false, item)
	pending_files(ui, p)
}

// viewed_unread is what's unread in the conversation being looked at,
// up to where it has been read, and how many unread mention us. Call
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

// message_file is what's known of a file a message offers: how its
// transfer is going, if there's one here.
@(private = "file")
message_file :: proc(v: ^conn.View, m: conn.View_Message) -> conn.View_File {
	if f, ok := v.files[m.id]; ok {
		return f
	}
	return {name = m.text, size = m.file_size, outgoing = m.sender == v.me, state = .Unknown}
}

// message_height is how far drawing msgs[i] at `width` moves the layout
// down (timeline_message).
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
	// The cache is for the timeline's width; a reply is laid out
	// narrower, by its indent.
	width := full - (REPLY_INDENT if is_indented(st, m) else 0) - avatar_column(ui)
	_, l, _, _ := map_entry(&st.layouts, m.id)
	shown, _, _, _ := message_text(ui, m.text)
	if picture_gone(m) {
		// Which also tells the layout kept from when it had one apart.
		shown = PICTURE_GONE_TEXT
	}
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
		kind = .System // drawn as DELETED_TEXT, like a kind there's no drawing for
	}
	// Measured as chat_message draws it (rich_text).
	#partial switch kind {
	case .Text:
		text := message_rich(ui, m.text)
		body = rich_height(ctx, &text, width)
	case .Image:
		if picture_gone(m) {
			text := rich_plain(PICTURE_GONE_TEXT)
			body = rich_height(ctx, &text, width)
			break
		}
		_, h := image_display_size(ctx, int(m.image.width), int(m.image.height), int(width))
		body = i32(h)
	case .System:
		text := rich_plain(DELETED_TEXT if .Deleted in m.flags else system_line(ui, m))
		body = rich_height(ctx, &text, width)
	case:
		text := rich_plain(UNKNOWN_KIND_TEXT)
		body = rich_height(ctx, &text, width)
	}
	h := chat_block_height(ctx, merged, body, reply_line)
	if m.kind == .File && .Deleted not_in m.flags {
		h = file_block_height(ui, message_file(&ui.view, m), width, merged, reply_line)
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

// local_day is the local day a message was posted, as a number that
// goes up by one a day.
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

// timeline_message draws msgs[i], and says where in the layout the
// message itself starts (after a day's line, the "new messages" line, and
// the gap over a header).
@(private = "file")
timeline_message :: proc(
	ui: ^UI,
	st: ^UI_Timeline,
	msgs: []conn.View_Message,
	i: int,
	full: i32,
) -> (
	from: i32,
) {
	ctx := &ui.ctx
	v := &ui.view
	m := msgs[i]
	new_day, new_line, merged, tight := message_flags(ui, st, msgs, i)
	seconds := proto.Unix_Time(m.time / 1000)
	if new_day {
		day_line(ui, seconds)
	}
	if new_line {
		rule(ui, "New messages", NEW_LINE_COLOR)
	}
	// A reply, indented: everything of it from here on.
	indent: i32 = REPLY_INDENT if is_indented(st, m) else 0
	column := avatar_column(ui)
	width := full - indent - column
	mu.get_layout(ctx).indent += indent + column
	defer mu.get_layout(ctx).indent -= indent + column
	from = mu.get_layout(ctx).next_row + (0 if merged else ctx.style.spacing)
	if tight {
		// Its reply's line, and the message close under it.
		from = mu.get_layout(ctx).next_row + 1 + ctx.style.spacing
		reply_line(ui, st, m, width)
	}
	defer if has_thread_line(st, m) {
		thread_line(ui, st, m)
	}
	name := "someone"
	if acc, ok := v.accounts[m.sender]; ok {
		name = acc.display
	}
	header :=
		"" if merged else fmt.tprintf("%s  %s%s%s%s", chat_time(ui, seconds), name, "  (edited)" if m.edited != 0 && .Deleted not_in m.flags else "", "  - pinned" if .Pinned in m.flags else "", forward_note(ui, m))
	header_color := author_color(v, m.sender)
	item := i64(m.id) * ITEMS_PER_MESSAGE
	if !merged {
		// The picture, beside the header (which comes after the gap);
		// or in the compact chat, the dot beside it.
		layout := mu.get_layout(ctx)
		y := layout.body.y + layout.next_row + (MERGED_GAP if tight else ctx.style.spacing)
		if ui.settings.chat_pictures {
			size := avatar_size(ctx)
			avatar(ui, m.sender, {layout.body.x + indent, y, size, size})
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
		chat_message(ui, header, header_color, &text, CHAT_DIM_COLOR, merged, item, tight)
		return from
	}
	#partial switch m.kind {
	case .File:
		file_message(ui, header, header_color, m.id, message_file(v, m), merged, item, tight)
	case .Text:
		text := message_rich(ui, m.text)
		chat_message(ui, header, header_color, &text, ctx.style.colors[.TEXT], merged, item, tight)
		message_files(ui, st.key.conv, m)
	case .Image:
		if picture_gone(m) {
			text := rich_plain(PICTURE_GONE_TEXT)
			chat_message(ui, header, header_color, &text, CHAT_DIM_COLOR, merged, item, tight)
			break
		}
		img := v.blobs[m.image.blob] or_else conn.View_Image{state = .Wanted}
		chat_image(
			ui,
			header,
			header_color,
			u64(m.image.blob),
			m.image,
			img,
			merged,
			item,
			available = int(width),
			tight = tight,
		)
	case .System:
		text := rich_plain(system_line(ui, m))
		chat_message(ui, header, header_color, &text, CHAT_DIM_COLOR, merged, item, tight)
	case:
		text := rich_plain(UNKNOWN_KIND_TEXT)
		chat_message(ui, header, header_color, &text, CHAT_DIM_COLOR, merged, item, tight)
	}
	reaction_chips(ui, m, width)
	return from
}

/*
reply_line is the dim line over a reply: a mark, and who wrote what it
replies to and the start of it, cut to the width. Until the root is here
it says only that it's a reply, and the root is asked for. Clicking it
opens the thread.
*/
@(private = "file")
reply_line :: proc(ui: ^UI, st: ^UI_Timeline, m: conn.View_Message, width: i32) {
	ctx := &ui.ctx
	v := &ui.view
	font := ctx.style.font
	mu.layout_row(ctx, {-1}, 1)
	mu.layout_next(ctx) // the gap over it
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
		case root.kind == .Image:
			said = "a picture"
		case root.kind == .File:
			said = fmt.tprintf("the file %s", root.text)
		case:
			shown, _ := conn.mentions_display(root.text, v.accounts, v.me)
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
	if thread_link(ui, text, r, CHAT_DIM_COLOR) {
		open_thread(ui, key)
	}
}

// thread_line is the line under a root with replies: how many, and when
// the last was, if it's here. Clicking it opens the thread.
@(private = "file")
thread_line :: proc(ui: ^UI, st: ^UI_Timeline, m: conn.View_Message) {
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
	if thread_link(ui, text, r, CHAT_NAME_COLOR) {
		open_thread(ui, {st.key.conv, m.id})
	}
}

// thread_link draws a line that opens a thread, in `r`: lit while the
// pointer is over it; true when it's clicked.
@(private = "file")
thread_link :: proc(ui: ^UI, text: string, r: mu.Rect, color: mu.Color) -> bool {
	ctx := &ui.ctx
	font := ctx.style.font
	hit := mu.Rect{r.x, r.y, min(ctx.text_width(font, text), r.w), r.h}
	over := mu.mouse_over(ctx, hit)
	mu.draw_text(ctx, font, text, {r.x, r.y}, LINK_HOVER_COLOR if over else color)
	if !over {
		return false
	}
	ui.chat.hovering = true // a hand, as over a link
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

/*
A message's reactions are a row of chips under it, each its emoji and how
many reacted with it, ours lit; they wrap onto more rows when the width
runs out. Clicking one gives or takes back ours. reactions_height has to
agree with reaction_chips.
*/
@(private = "file")
Chip :: struct {
	r:     conn.Reaction,
	text:  string, // the emoji as shown, then the count
	icons: []conn.Emoji_Span, // the server's emoji in it
	w:     i32,
}

// The gap over the chips, and their height (logical pixels).
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
reaction_chips :: proc(ui: ^UI, m: conn.View_Message, width: i32) {
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
			background := mu.Color{60, 60, 60, 255}
			switch {
			case c.r.me:
				background = {70, 95, 140, 255}
			case ctx.hover_id == id:
				background = ctx.style.colors[.BUTTON_HOVER]
			}
			if ctx.hover_id == id && c.r.me {
				background = {85, 115, 165, 255}
			}
			mu.draw_rect(ctx, rect, background)
			font := ctx.style.font
			pos := mu.Vec2{rect.x + 6, rect.y + (rect.h - ctx.text_height(font)) / 2}
			mu.draw_text(ctx, font, c.text, pos, ctx.style.colors[.TEXT])
			draw_chip_emoji(ui, c, pos)
			if ctx.hover_id == id {
				reactors_hint(ui, m.id, c.r, rect)
			}
			if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} && ui.session != nil {
				conn.push_command(
					&ui.session.client.commands,
					conn.React_Command{id = m.id, emoji = strings.clone(c.r.emoji), on = !c.r.me},
				)
			}
			mu.pop_id(ctx)
		}
	}
}

// Who reacted, as asked for last (reactors_hint): not asked again while
// it's the same message, emoji and count.
Reactors_Asked :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned
	count: int,
}

// How many names a reaction's hint lists, and how many to a line.
@(private = "file")
REACTORS_SHOWN :: 15
@(private = "file")
REACTORS_PER_LINE :: 5

/*
reactors_hint is the hint over a reaction: the emoji's :name:, and who
reacted with it ("you" for us), the first REACTORS_SHOWN and how many
more. Who it was is asked of the server the first time the pointer is
on it, and again when the count has changed.
*/
@(private = "file")
reactors_hint :: proc(ui: ^UI, id: proto.Msg_Id, r: conn.Reaction, rect: mu.Rect) {
	v := &ui.view
	asked := &ui.reactors_asked
	name := r.emoji
	if !strings.has_prefix(name, ":") {
		first, _ := utf8.decode_rune_in_string(r.emoji)
		if index, ok := proto.emoji_index(first); ok {
			name = fmt.tprintf(":%s:", proto.emoji_name(proto.EMOJI[index]))
		}
	}
	have := v.reactors.id == id && v.reactors.emoji == r.emoji && v.reactors.total == r.count
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

// draw_chip_emoji draws the server's emoji over their placeholders in a
// chip's text, drawn at `pos`.
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

// system_line is what a system message says (a call's line, so far).
@(private = "file")
system_line :: proc(ui: ^UI, m: conn.View_Message) -> string {
	v := &ui.view
	name := "someone"
	if acc, ok := v.accounts[m.sender]; ok {
		name = acc.display
	}
	return fmt.tprintf(
		"\U0001F4DE %s",
		conn.system_text(m.system, m.system_arg, name, m.sender == v.me),
	)
}

// What's left of a deleted message.
@(private = "file")
DELETED_TEXT :: "message deleted"
// What a picture the server no longer keeps says (phase 15).
PICTURE_GONE_TEXT :: "picture no longer kept"

// picture_gone is whether a message was a picture that has been purged:
// it's still an Image, without one.
picture_gone :: proc(m: conn.View_Message) -> bool {
	return m.kind == .Image && m.image.blob == 0 && .Deleted not_in m.flags
}

// message_mouse is what the pointer does to a message laid out in
// `block`: on it, the message's bar is over it, and a right click opens
// its menu. And the one jumped to is lit up
// for a while; when it was jumped to as the first unread mention of us,
// so are the others.
@(private = "file")
message_mouse :: proc(ui: ^UI, st: ^UI_Timeline, m: conn.View_Message, block: mu.Rect) {
	ctx := &ui.ctx
	lit := st.lit == m.id
	if st.lit_mentions && st.lit_at != {} && m.id > st.unread_from && m.kind == .Text {
		lit ||= proto.mentions_account(m.text, ui.view.me)
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
	if .RIGHT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, block) {
		open_message_menu(ui, m, st.slot)
	}
	message_bar_track(ui, st.key.conv, st.slot, m, block)
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
	rule(ui, text, DAY_LINE_COLOR)
}

// rule is a line across the timeline with `text` in the middle of it, a
// row of the usual height.
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

/*
timeline_reading tells the network side which conversation is being
read, when that changes: the one whose timeline was drawn this frame and
is at its newest message, in a window that has the focus. Call after the
frame.
*/
timeline_reading :: proc(ui: ^UI, focused: bool) {
	st := &ui.timeline
	reading: proto.Conv_Id
	if st.shown && st.follow && focused {
		reading = st.key.conv
	}
	st.shown = false
	// A new session knows of nothing being read.
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
