package main

import "core:strings"

import "tui"

// Selecting text with the mouse. The terminal can't do it while the program
// takes the mouse, so a drag over the messages (or a thread) selects here: the
// cells between where it started and where it is are shown reversed, and when
// the button is let go their text is copied (to the clipboard, through the
// terminal). A click that doesn't move is a click, and opens the message's menu.

Selection :: struct {
	active: bool,
	pane:   tui.Rect, // the region the drag started in; the selection stays in it
	anchor: [2]int, // where it started (x, y)
	head:   [2]int, // where it is now
}

// sel_pane is the region of text under x, y that can be selected in.
sel_pane :: proc(g: Geometry, x, y: int) -> (tui.Rect, bool) {
	if g.thread.w > 0 && tui.rect_contains(g.thread, x, y) {
		return {g.thread.x, g.thread.y + 1, g.thread.w - 1, g.thread.h - 1}, true
	}
	if !g.thread_over && tui.rect_contains(g.timeline, x, y) {
		return {g.timeline.x, g.timeline.y, g.timeline.w - 1, g.timeline.h}, true
	}
	return {}, false
}

// sel_ordered gives the ends of the selection, first to last in reading order.
sel_ordered :: proc(s: Selection) -> (from, to: [2]int) {
	a, b := s.anchor, s.head
	if b.y < a.y || b.y == a.y && b.x < a.x {
		a, b = b, a
	}
	return a, b
}

// sel_contains is whether the cell is selected.
sel_contains :: proc(s: Selection, x, y: int) -> bool {
	if !s.active || !tui.rect_contains(s.pane, x, y) {
		return false
	}
	from, to := sel_ordered(s)
	if y < from.y || y > to.y {
		return false
	}
	if y == from.y && x < from.x {
		return false
	}
	return !(y == to.y && x > to.x)
}

// sel_text is the text of the selected cells in a drawn screen.
sel_text :: proc(s: Selection, b: ^tui.Buffer) -> string {
	out: strings.Builder
	strings.builder_init(&out, context.temp_allocator)
	from, to := sel_ordered(s)
	for y in max(from.y, s.pane.y) ..= min(to.y, s.pane.y + s.pane.h - 1) {
		line: strings.Builder
		strings.builder_init(&line, context.temp_allocator)
		for x in s.pane.x ..< s.pane.x + s.pane.w {
			if !sel_contains(s, x, y) || x >= b.w || y >= b.h {
				continue
			}
			c := tui.cell_at(b, x, y)
			if c.width != 0 {
				strings.write_rune(&line, c.r)
			}
		}
		if y > max(from.y, s.pane.y) {
			strings.write_byte(&out, '\n')
		}
		strings.write_string(&out, strings.trim_right_space(strings.to_string(line)))
	}
	return strings.to_string(out)
}

// draw_selection shows the selected cells reversed.
draw_selection :: proc(a: ^App, b: ^tui.Buffer) {
	if !a.sel.active {
		return
	}
	from, to := sel_ordered(a.sel)
	for y in max(from.y, 0) ..= min(to.y, b.h - 1) {
		for x in 0 ..< b.w {
			if sel_contains(a.sel, x, y) {
				b.cells[y * b.w + x].style.attrs += {.Reverse}
			}
		}
	}
}
