package client

import "core:fmt"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// Threads are shown each in a window of their own beside the conversation:
// the thread's root at the top, its replies under it in a timeline of their
// own (ui_timeline.odin), and a composer for posting replies. Each window has
// its own scroll position, composer, typing line and text selection, which are
// kept per slot in ui.threads. A thread's timeline panel, composer text box
// and window are told apart by the slot.
//
// At most conn.MAX_THREADS threads are open. Opening another closes the one
// that was opened longest ago. Threads stay open while other conversations are
// looked at, until they are closed, their conversation is no longer ours, or
// the connection is lost. A window keeps its position while it is open, and
// can be rolled up to its title bar, which says the thread's conversation and
// how its root starts.
//
// In a narrow window there is no room beside the conversation. The thread of
// the conversation on screen that was opened last takes the conversation's
// place, with a button to go back to the conversation (which closes the
// thread).
//
// The network side keeps the replies of each open thread up to date
// (conn.Thread_Command).

UI_Thread :: struct {
	key:          conn.Timeline_Key, // {} for a free slot
	timeline:     UI_Timeline,
	buf:          ^[proto.MAX_CHAT_SIZE]u8, // made the first time it is needed (composer_buffer)
	len:          int,
	area:         Text_Area, // the box it is written in
	// The reply of ours being edited in it, and its conversation (Composer).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	opened:       u64, // when it was opened, by ui.threads_opened
	placed:       bool, // whether its window's position has been set since it was opened
	readonly:     bool, // the thread is read-only (it is part of a DM whose other participant is deleted)
	// Whether it is in the conversation on screen (threads_sync).
	here:         bool,
	// Its window is rolled up to the title bar, and how tall it was before.
	rolled:       bool,
	unrolled_h:   i32,
	// Files to send with the next reply (ui_attachments.odin).
	files:        [dynamic]Picked_File,
	// Where its window was in the last frame, and how far up: what is dropped
	// there is for it (drop_target).
	rect:         mu.Rect,
	zindex:       i32,
}

@(private = "file")
THREAD_WINDOW :: "Thread"

ui_threads_destroy :: proc(ui: ^UI) {
	for &t in ui.threads {
		timeline_destroy(&t.timeline)
	}
}

// open_thread opens a thread's window, or brings it to the front if it is
// already open. Either way its composer takes the focus. Call with the View
// locked.
open_thread :: proc(ui: ^UI, key: conn.Timeline_Key, readonly := false) {
	if key.conv == 0 || key.root == 0 || ui.session == nil {
		return
	}
	slot := 0
	for t, i in ui.threads {
		if t.key == key {
			slot = i + 1
		}
	}
	if slot == 0 {
		// A free slot, or the one that was opened longest ago.
		for t, i in ui.threads {
			if t.key == {} {
				slot = i + 1
				break
			}
			if slot == 0 || t.opened < ui.threads[slot - 1].opened {
				slot = i + 1
			}
		}
		close_thread(ui, slot)
		t := &ui.threads[slot - 1]
		t.key = key
		t.timeline.slot = slot
		conn.push_command(
			&ui.session.client.commands,
			conn.Thread_Command{thread = key, open = true},
		)
	}
	t := &ui.threads[slot - 1]
	ui.threads_opened += 1
	t.opened = ui.threads_opened
	t.placed = false
	t.readonly = readonly
	t.here = key.conv == ui.view.viewing
	focus_composer(ui, composer_of(ui, slot), -1)
}

// close_thread closes the thread in a slot, if there is one.
close_thread :: proc(ui: ^UI, slot: int) {
	t := &ui.threads[slot - 1]
	if t.key == {} {
		return
	}
	if ui.session != nil {
		conn.push_command(
			&ui.session.client.commands,
			conn.Thread_Command{thread = t.key, open = false},
		)
	}
	timeline_destroy(&t.timeline)
	picked_files_destroy(&t.files)
	// The slot keeps its text buffer for the next thread that is opened in it.
	buf := t.buf
	t^ = {}
	t.buf = buf
	if ui.select.panel == timeline_select_panel(slot) {
		ui.select.panel = .None
	}
}

// timeline_conv is the conversation of a timeline: the one on screen (slot 0)
// or a thread window's, which may be another. Call with the View locked.
timeline_conv :: proc(ui: ^UI, slot: int) -> proto.Conv_Id {
	if slot > 0 && slot <= len(ui.threads) {
		return ui.threads[slot - 1].key.conv
	}
	return ui.view.viewing
}

// narrow_thread is the slot of the thread shown in a narrow window, which is
// the one of the conversation on screen that was opened last, or 0 if none
// is open.
narrow_thread :: proc(ui: ^UI) -> int {
	slot := 0
	for t, i in ui.threads {
		if t.key != {} && t.here && (slot == 0 || t.opened > ui.threads[slot - 1].opened) {
			slot = i + 1
		}
	}
	return slot
}

// threads_sync closes the threads whose conversation is gone (left, or no
// longer ours), and all of them without a connection, and notes which are in
// the conversation on screen. Call once a frame, before anything is laid out.
threads_sync :: proc(ui: ^UI) {
	v := ui.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	for &t, i in ui.threads {
		switch {
		case t.key == {}:
		case ui.session == nil:
			timeline_destroy(&t.timeline)
			buf := t.buf
			t = {}
			t.buf = buf
		case v.status != .Connected || !conversation_known(v, t.key.conv):
			close_thread(ui, i + 1)
		case:
			t.here = t.key.conv == v.viewing
		}
	}
}

// conversation_known is whether a conversation is one of ours: a channel we
// are in, or a DM or group. Before the list of them has arrived, any is. Call
// with the View locked.
@(private = "file")
conversation_known :: proc(v: ^conn.View, conv: proto.Conv_Id) -> bool {
	if len(v.channels) == 0 {
		return true
	}
	for ch in v.channels {
		if ch.id == conv {
			return true
		}
	}
	for dm in v.dms {
		if dm.id == conv {
			return true
		}
	}
	return false
}

// thread_windows draws the open threads' windows over the main one. In a
// narrow window, side_panel shows one in the conversation's place instead.
thread_windows :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	if ui.session == nil || ui.page == .Settings || (ui.narrow && ui.page == .Main) {
		return
	}
	v := ui.view
	sync.guard(&v.mutex)
	for &t, i in ui.threads {
		if t.key == {} {
			continue
		}
		slot := i + 1
		mu.push_id(ctx, uintptr(slot))
		defer mu.pop_id(ctx)
		if !t.placed {
			t.placed = true
			w := clamp(window_w / 3, 300, 460)
			h := clamp(window_h - 140, 240, 700)
			step := i32(slot - 1) * 28
			if cnt := mu.get_container(ctx, THREAD_WINDOW); cnt != nil {
				// Opened again while rolled up: unrolled. A window left rolled
				// up by a thread that was closed gets a new place.
				if t.rolled {
					t.rolled = false
					cnt.rect.h = t.unrolled_h if t.unrolled_h > 0 else h
				}
				if !cnt.open || cnt.rect.w == 0 || cnt.rect.h <= ctx.style.title_height {
					cnt.rect = {max(window_w - w - 40 - step, 0), 70 + step, w, h}
				}
				cnt.open = true
				mu.bring_to_front(ctx, cnt)
				ctx.hover_root, ctx.next_hover_root = cnt, cnt
			}
		}
		opts := mu.Options{.NO_RESIZE, .NO_SCROLL} if t.rolled else {}
		if !mu.begin_window(ctx, THREAD_WINDOW, {}, opts) {
			close_thread(ui, slot) // closed with the title bar's button
			continue
		}
		keep_in_window(ui) // dragged: kept below the top bar, on screen
		cnt := mu.get_current_container(ctx)
		was_rolled := t.rolled
		thread_title(ui, slot, cnt)
		t.rect, t.zindex = cnt.rect, cnt.zindex
		// Not while rolled up, nor in the frame it is rolled up or down in,
		// whose window was laid out at the size it had before.
		if !t.rolled && !was_rolled {
			thread_panel(ui, slot, false)
		}
		mu.end_window(ctx)
	}
}

// thread_title draws a thread window's title bar over the one microui drew
// (the window is known by its title, so that stays the same): the thread's
// conversation and the start of its root, then a button that rolls the window
// up to its title bar or back down, and the close button again. Call right
// after mu.begin_window, with the View locked.
@(private = "file")
thread_title :: proc(ui: ^UI, slot: int, cnt: ^mu.Container) {
	ctx := &ui.ctx
	v := ui.view
	t := &ui.threads[slot - 1]
	bar := mu.Rect{cnt.rect.x, cnt.rect.y, cnt.rect.w, ctx.style.title_height}
	close := mu.Rect{bar.x + bar.w - bar.h, bar.y, bar.h, bar.h}
	roll := mu.Rect{close.x - bar.h, bar.y, bar.h, bar.h}
	text_r := bar
	text_r.w = max(roll.x - bar.x, 0)

	// Inside the window, drawing and the pointer are clipped to its body,
	// which leaves out the title bar. Pop that for now, down to the window's
	// whole rect, and put it back after.
	mu.pop_clip_rect(ctx)
	defer mu.push_clip_rect(ctx, cnt.body)

	id := mu.get_id(ctx, "!roll")
	mu.update_control(ctx, id, roll, {})
	hint := "Roll down" if t.rolled else "Roll up"
	if ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, roll
	}
	if .LEFT in ctx.mouse_released_bits && ctx.hover_id == id {
		if t.rolled {
			t.rolled = false
			cnt.rect.h = max(t.unrolled_h, 3 * ctx.style.title_height)
		} else {
			t.rolled = true
			t.unrolled_h = cnt.rect.h
			cnt.rect.h = ctx.style.title_height
			if ui.select.panel == timeline_select_panel(slot) {
				ui.select.panel = .None
			}
		}
		ui_redraw(ui)
	}

	title := fmt.tprintf("Thread in %s", conversation_name(v, t.key.conv))
	if said, ok := thread_root_said(ui, t.key); ok {
		title = fmt.tprintf("%s - %s", conversation_name(v, t.key.conv), said)
	}
	ctx.draw_frame(ctx, bar, .TITLE_BG)
	mu.draw_control_text(ctx, title, text_r, .TITLE_TEXT, {})
	if ctx.hover_id == id {
		mu.draw_rect(ctx, roll, ctx.style.colors[.BUTTON_HOVER])
	}
	mu.draw_icon(ctx, .COLLAPSED if t.rolled else .EXPANDED, roll, ctx.style.colors[.TITLE_TEXT])
	mu.draw_icon(ctx, .CLOSE, close, ctx.style.colors[.TITLE_TEXT])
}

// thread_panel lays out a thread: a line saying who is typing in it (or that a
// reply is being edited), its timeline, and its composer. `back` adds a
// button before the line that goes back to the conversation (in the narrow
// layout). Call with the View locked.
thread_panel :: proc(ui: ^UI, slot: int, back: bool) {
	ctx := &ui.ctx
	v := ui.view
	t := &ui.threads[slot - 1]
	composer := composer_of(ui, slot)

	status := typing_text(v, t.key.root, t.key.conv)
	if editing := composer_status(composer); editing != "" {
		status = editing
	}
	if status == "" {
		status = "Replies in a thread"
		if root, ok := thread_root_message(ui, t.key); ok {
			if acc, known := v.accounts[root.sender]; known {
				status = fmt.tprintf("Replies to %s", acc.display)
			}
		}
	}
	when TIMELINE_DEBUG {
		status = fmt.tprintf(
			"%s  [%d laid out, %d off]",
			status,
			t.timeline.laid_out,
			t.timeline.mismatched,
		)
	}
	if back {
		mu.layout_row(ctx, {70, -1})
		if .SUBMIT in icon_button(ui, "thread back", .Back, "Back") {
			close_thread(ui, slot)
			return
		}
	} else {
		mu.layout_row(ctx, {-1})
	}
	dim_label(ctx, status)

	input_h: i32 = 0
	files_h: i32 = 0
	width := panel_width(ctx)

	// A thread in a channel we may not write in can be read, not replied to.
	no_write := !t.readonly && .Write not_in rights_in(v, t.key.conv)
	if no_write {
		input_h = read_only_height(ctx)
	} else if !t.readonly {
		input_h = composer_height(ui, composer)
		files_h = composer_files_height(ui, composer, width)
	}
	mu.layout_row(ctx, {-1}, -(input_h + files_h + ctx.style.spacing + 1))
	timeline(ui, &t.timeline, t.key, t.readonly)
	if no_write {
		read_only_line(ui)
		return
	}
	if t.readonly {
		return
	}

	composer_files(ui, composer, width)

	composer_bar(
		ui,
		composer,
		{send_id = "send", verb = "Reply", typing = conn.Typing_Command{thread = t.key}},
	)
}
