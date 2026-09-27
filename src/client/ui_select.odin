package client

import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"

/*
Selecting text in the chat and the log with the mouse, and copying it
with Ctrl+C.

A panel's text comes in items - a log line, a chat message's header or
its body - numbered in the order they're shown, by numbers that stay the
same from frame to frame (the chat's and the log's running totals), and
a place in the text is an item and a byte offset into it. The selection
runs from where the button went down (anchor) to where the pointer is
now (focus), in whichever order they come.

Nothing is kept about where text was drawn: each frame, as the panel
lays its lines out, select_line finds where the pointer is among them
and paints the selected part, and select_item collects the selected
text, so it's there for Ctrl+C without going back over the panel.
*/

Select_Panel :: enum {
	None,
	Chat,
	Log,
	DM, // the open conversation on the buddy screen
}

Text_Pos :: struct {
	item:   i64,
	offset: int, // bytes into the item's text
}

Selection :: struct {
	panel:     Select_Panel, // where the selection is; None for no selection
	anchor:    Text_Pos,
	focus:     Text_Pos,
	dragging:  bool,

	// This frame's, for the panel being drawn (select_begin to
	// select_end).
	drawing:   Select_Panel,
	pressed:   bool, // the button went down over the panel
	hit:       Text_Pos, // the place under the pointer, so far
	found:     bool, // `hit` is set
	over_text: bool, // the pointer is on some text: an I-beam cursor
	text:      strings.Builder, // what's selected, for Ctrl+C
	last_item: i64, // the item text was last added from
}

SELECTION_COLOR :: mu.Color{55, 85, 135, 255}

ui_select_destroy :: proc(ui: ^UI) {
	strings.builder_destroy(&ui.select.text)
}

// has_selection is whether any text in `panel` is selected.
has_selection :: proc(s: ^Selection, panel: Select_Panel) -> bool {
	return s.panel == panel && s.anchor != s.focus
}

// select_begin starts a panel's selectable text, inside mu.begin_panel.
select_begin :: proc(ui: ^UI, panel: Select_Panel) {
	ctx := &ui.ctx
	s := &ui.select
	s.drawing = panel
	s.found = false
	s.last_item = min(i64)
	strings.builder_reset(&s.text)
	body := mu.get_current_container(ctx).body
	s.pressed = .LEFT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, body)
}

/*
select_end finishes the panel's text, just before mu.end_panel: a press
starts a new selection, a drag moves its end, and Ctrl+C copies it.
Dragging past the top or bottom scrolls the panel along.
*/
select_end :: proc(ui: ^UI) {
	ctx := &ui.ctx
	s := &ui.select
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
	// A focused text box has Ctrl+C for itself.
	if ctx.focus_id == 0 &&
	   .C in ctx.key_pressed_bits &&
	   .CTRL in ctx.key_down_bits &&
	   .ALT not_in ctx.key_down_bits &&
	   has_selection(s, panel) {
		ctx.key_pressed_bits -= {.C}
		set_clipboard(nil, strings.to_string(s.text))
	}
}

// select_item adds an item's selected text, if any, to what Ctrl+C
// copies. Call it once per item, in order.
select_item :: proc(ui: ^UI, item: i64, text: string) {
	s := &ui.select
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

/*
select_line is one line of an item as it's drawn: text[start:end] at
`pos`. It paints the selected part of it (so call it before drawing the
text), and works out whether the pointer is on the line, or past it,
for the place a press or a drag lands on.
*/
select_line :: proc(ui: ^UI, item: i64, text: string, start, end: int, pos: mu.Vec2) {
	ctx := &ui.ctx
	s := &ui.select
	font := ctx.style.font
	h := ctx.text_height(font)
	mouse := ctx.mouse_pos

	// The line the pointer is on, or else the last line above it, is
	// where it lands: at the end of that line if it's below it. Above
	// every line, it lands at the start of the first.
	if mouse.y >= pos.y {
		if mouse.y < pos.y + h {
			s.hit = {item, offset_at(ctx, font, text, start, end, mouse.x - pos.x)}
			width := ctx.text_width(font, text[start:end])
			if mouse.x >= pos.x && mouse.x < pos.x + width && mu.mouse_over(ctx, {pos.x, pos.y, width, h}) {
				s.over_text = true
			}
		} else {
			s.hit = {item, end}
		}
		s.found = true
	} else if !s.found {
		s.hit = {item, start}
		s.found = true
	}

	lo, hi, ok := selected_range(s, item, len(text))
	if !ok {
		return
	}
	a, b := max(lo, start), min(hi, end)
	if a >= b {
		return
	}
	x := pos.x + ctx.text_width(font, text[start:a])
	mu.draw_rect(ctx, {x, pos.y, ctx.text_width(font, text[a:b]), h}, SELECTION_COLOR)
}

// selected_range is the part of an item's text, `length` bytes long,
// that's selected in the panel being drawn.
@(private = "file")
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

// offset_at is the place in text[start:end] nearest `x` pixels from
// where it starts, between two characters.
@(private = "file")
offset_at :: proc(ctx: ^mu.Context, font: mu.Font, text: string, start, end: int, x: i32) -> int {
	w: i32
	for ch, i in text[start:end] {
		size := utf8.rune_size(ch)
		cw := ctx.text_width(font, text[start + i:][:size])
		if x < w + cw / 2 {
			return start + i
		}
		w += cw
	}
	return end
}
