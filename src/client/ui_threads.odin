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
// that was opened longest ago. Threads belong to the conversation that is on
// screen, so looking at another conversation closes them. A window keeps its
// position while it is open.
//
// In a narrow window there is no room beside the conversation. The thread that
// was opened last takes the conversation's place, with a button to go back to
// the conversation (which closes the thread).
//
// The network side keeps the replies of each open thread up to date
// (conn.Thread_Command).

UI_Thread :: struct {
	key:          conn.Timeline_Key, // {} for a free slot
	timeline:     UI_Timeline,
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it is written in
	// The reply of ours being edited in it, and its conversation (Composer).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	opened:       u64, // when it was opened, by ui.threads_opened
	placed:       bool, // whether its window's position has been set since it was opened
	readonly:     bool, // the thread is read-only (it is part of a DM whose other participant is deleted)
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
	t^ = {}
	if ui.select.panel == timeline_select_panel(slot) {
		ui.select.panel = .None
	}
}

// narrow_thread is the slot of the thread shown in a narrow window, which is
// the one opened last, or 0 if none is open.
narrow_thread :: proc(ui: ^UI) -> int {
	slot := 0
	for t, i in ui.threads {
		if t.key != {} && (slot == 0 || t.opened > ui.threads[slot - 1].opened) {
			slot = i + 1
		}
	}
	return slot
}

// thread_windows draws the open threads' windows over the main one. In a
// narrow window, side_panel shows one in the conversation's place instead.
// Threads that don't belong to the conversation on screen are closed.
thread_windows :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	for &t, i in ui.threads {
		switch {
		case t.key == {}:
		case ui.session == nil:
			timeline_destroy(&t.timeline)
			t = {}
		case t.key.conv != v.viewing || v.status != .Connected:
			close_thread(ui, i + 1)
		}
	}
	if ui.session == nil || ui.page == .Settings || (ui.narrow && ui.page == .Main) {
		return
	}
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
				if !cnt.open || cnt.rect.w == 0 {
					cnt.rect = {max(window_w - w - 40 - step, 0), 70 + step, w, h}
				}
				cnt.open = true
				mu.bring_to_front(ctx, cnt)
				ctx.hover_root, ctx.next_hover_root = cnt, cnt
			}
		}
		if !mu.begin_window(ctx, THREAD_WINDOW, {}) {
			close_thread(ui, slot) // closed with the title bar's button
			continue
		}
		keep_in_window(ui) // dragged: kept below the top bar, on screen
		if cnt := mu.get_current_container(ctx); cnt != nil {
			t.rect, t.zindex = cnt.rect, cnt.zindex
		}
		thread_panel(ui, slot, false)
		mu.end_window(ctx)
	}
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

	status := typing_text(v, t.key.root)
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
