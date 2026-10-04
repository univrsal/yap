package client

import "core:fmt"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Threads, each in a window of its own beside the conversation: the
thread's root at the top, its replies under it in a timeline of their own
(ui_timeline.odin), and a composer that posts replies. Each window has
its own scroll position, composer, typing line and text to select, by
its slot in ui.threads: its timeline's panel, its composer's text box
and its window are told apart by the slot.

At most conn.MAX_THREADS are open; opening another closes the one opened
longest ago. They're the conversation's on screen: looking at another
closes them. A window keeps its place while it's open.

In a narrow window there's no room beside the conversation: the thread
opened last takes the conversation's place, with a button back to it
(which closes the thread).

The network side keeps each open thread's replies up to date
(conn.Thread_Command).
*/

UI_Thread :: struct {
	key:          conn.Timeline_Key, // {} for a free slot
	timeline:     UI_Timeline,
	buf:          [proto.MAX_CHAT_SIZE]u8,
	len:          int,
	area:         Text_Area, // the box it's written in
	// The reply of ours being edited in it, and where (Composer).
	editing:      proto.Msg_Id,
	editing_conv: proto.Conv_Id,
	opened:       u64, // when it was opened, by ui.threads_opened
	placed:       bool, // its window's place has been set since it opened
	// Files to go with the next reply (ui_attachments.odin).
	files:        [dynamic]Picked_File,
	// Where its window was last frame, and how far up: what's dropped
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

/*
open_thread opens a thread's window, or brings it to the front if it's
open; either way its composer takes the focus. Call with the View
locked.
*/
open_thread :: proc(ui: ^UI, key: conn.Timeline_Key) {
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
		// A free slot, or the one opened longest ago.
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
	focus_composer(ui, composer_of(ui, slot), -1)
}

// close_thread closes the thread in a slot, if there's one.
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

// narrow_thread is the slot of the thread shown in a narrow window: the
// one opened last; 0 if none is open.
narrow_thread :: proc(ui: ^UI) -> int {
	slot := 0
	for t, i in ui.threads {
		if t.key != {} && (slot == 0 || t.opened > ui.threads[slot - 1].opened) {
			slot = i + 1
		}
	}
	return slot
}

/*
thread_windows draws the open threads' windows, over the main one; in a
narrow window side_panel shows one in the conversation's place instead.
Threads not of the conversation on screen are closed.
*/
thread_windows :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	v := &ui.view
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
		if cnt := mu.get_current_container(ctx); cnt != nil {
			t.rect, t.zindex = cnt.rect, cnt.zindex
		}
		thread_panel(ui, slot, false)
		mu.end_window(ctx)
	}
}

/*
thread_panel lays out a thread: a line saying who's typing in it (or
that a reply is being edited), its timeline, and its composer. `back`
puts a button before the line that goes back to the conversation (the
narrow layout). Call with the View locked.
*/
thread_panel :: proc(ui: ^UI, slot: int, back: bool) {
	ctx := &ui.ctx
	v := &ui.view
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
		if .SUBMIT in stable_button(ctx, "thread back", "Back") {
			close_thread(ui, slot)
			return
		}
	} else {
		mu.layout_row(ctx, {-1})
	}
	with_text_color(ctx, CHAT_DIM_COLOR, status, label_proc)

	input_h := composer_height(ui, composer)
	width := panel_width(ctx)
	files_h := composer_files_height(ui, composer, width)
	mu.layout_row(ctx, {-1}, -(input_h + files_h + ctx.style.spacing + 1))
	timeline(ui, &t.timeline, t.key)
	composer_files(ui, composer, width)

	composer_row(ui, input_h, 4)
	completion_keys(ui, composer)
	composer_keys(ui, composer)
	res, box := composer_box(ui, composer)
	completion_update(ui, composer)
	if .CHANGE in res && t.len > 0 && ui.session != nil && t.editing == 0 {
		conn.push_command(&ui.session.client.commands, conn.Typing_Command{thread = t.key})
	}
	send := .SUBMIT in res
	composer_buttons(ui, input_h, 4)
	attach_button(ui, composer)
	emoji_button(ui, composer)
	preview_button(ui, composer)
	if .SUBMIT in icon_button(ui, "send", .Send, "Save" if t.editing != 0 else "Reply") {
		send = true
	}
	mu.layout_end_column(ctx)
	if !send {
		return
	}
	// Enter takes the focus away from the box; keep typing instead.
	mu.set_focus(ctx, box)
	composer_send(ui, composer)
}
