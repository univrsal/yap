package core

import mu "vendor:microui"
import "client:conn"
import "core:strings"

Select_Panel :: enum {
	None,
	Chat,
	Log,
	// The thread windows' (ui/threads.odin), by slot.
	Thread_1,
	Thread_2,
	Thread_3,
	Thread_4,
}

#assert(int(Select_Panel.Thread_4) - int(Select_Panel.Thread_1) + 1 == conn.MAX_THREADS)

Text_Pos :: struct {
	item:   i64,
	offset: int, // byte offset into the item's text
}

Selection :: struct {
	panel:     Select_Panel, // the panel the selection is in; None for no selection
	anchor:    Text_Pos,
	focus:     Text_Pos,
	dragging:  bool,

	// This frame's state for the panel being drawn (select_begin to
	// select_end).
	drawing:   Select_Panel,
	pressed:   bool, // the button went down over the panel
	hit:       Text_Pos, // the place under the pointer, so far
	found:     bool, // `hit` is set
	over_text: bool, // the pointer is on some text or a text box, so it shows an I-beam cursor
	text:      strings.Builder, // the selected text, for Ctrl+C
	last_item: i64, // the item that text was last added from
}

select_destroy :: proc(env: ^Env) {
	strings.builder_destroy(&env.select.text)
}

// has_selection is whether any text in `panel` is selected.
has_selection :: proc(s: ^Selection, panel: Select_Panel) -> bool {
	return s.panel == panel && s.anchor != s.focus
}

// select_begin starts a panel's selectable text, inside mu.begin_panel.
select_begin :: proc(env: ^Env, panel: Select_Panel) {
	ctx := &env.ctx
	s := &env.select
	s.drawing = panel
	s.found = false
	s.last_item = min(i64)
	strings.builder_reset(&s.text)
	body := mu.get_current_container(ctx).body
	s.pressed = .LEFT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, body)
}

// select_end finishes the panel's text, just before mu.end_panel. A press
// starts a new selection, a drag moves its end, and Ctrl+C copies it. Dragging
// past the top or bottom scrolls the panel along.
select_end :: proc(env: ^Env) {
	ctx := &env.ctx
	s := &env.select
	panel := s.drawing
	s.drawing = .None
	if s.pressed && s.found {
		s.panel = panel
		s.anchor, s.focus = s.hit, s.hit
		s.dragging = true
	}
	if s.panel != panel {
		return
	}
	if s.dragging {
		if .LEFT not_in ctx.mouse_down_bits {
			s.dragging = false
		} else if s.found {
			s.focus = s.hit
		}
	}
	if s.dragging {
		cnt := mu.get_current_container(ctx)
		body := cnt.body
		y := ctx.mouse_pos.y
		// microui keeps the scroll inside the content.
		if y < body.y {
			cnt.scroll.y -= max((body.y - y) / 2, 1)
		} else if y >= body.y + body.h {
			cnt.scroll.y += max((y - body.y - body.h) / 2, 1)
		}
	}
	// A focused text box handles Ctrl+C itself.
	if ctx.focus_id == 0 &&
	   .C in ctx.key_pressed_bits &&
	   .CTRL in ctx.key_down_bits &&
	   .ALT not_in ctx.key_down_bits &&
	   has_selection(s, panel) {
		ctx.key_pressed_bits -= {.C}
		ctx.textbox_state.set_clipboard(ctx.textbox_state.clipboard_user_data, strings.to_string(s.text))
	}
}

// select_item adds an item's selected text, if any, to what Ctrl+C copies.
// Call it once per item, in order.
select_item :: proc(env: ^Env, item: i64, text: string) {
	s := &env.select
	lo, hi, ok := selected_range(s, item, len(text))
	if !ok {
		return
	}
	if strings.builder_len(s.text) > 0 && item != s.last_item {
		strings.write_byte(&s.text, '\n')
	}
	strings.write_string(&s.text, text[lo:hi])
	s.last_item = item
}

// selected_range is the part of an item's text (`length` bytes long) that is
// selected in the panel being drawn.
selected_range :: proc(s: ^Selection, item: i64, length: int) -> (lo, hi: int, ok: bool) {
	if !has_selection(s, s.drawing) {
		return
	}
	first, last := s.anchor, s.focus
	if last.item < first.item || (last.item == first.item && last.offset < first.offset) {
		first, last = last, first
	}
	if item < first.item || item > last.item {
		return
	}
	lo = first.offset if item == first.item else 0
	hi = last.offset if item == last.item else length
	lo, hi = clamp(lo, 0, length), clamp(hi, 0, length)
	return lo, hi, lo < hi
}
