package ui

import "core"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"


// Selecting text in the chat and the log with the mouse, and copying it with
// Ctrl+C.
//
// A panel's text is made up of items (a log line, a chat message's header or
// its body). They are numbered in the order they are shown, with numbers that
// stay the same from frame to frame (the chat's and the log's running totals).
// A place in the text is an item plus a byte offset into it. The selection
// runs from where the button went down (anchor) to where the pointer is now
// (focus), in whichever order they are.
//
// Nothing is stored about where text was drawn. Each frame, while the panel
// lays out its lines, select_line finds where the pointer is among them and
// paints the selected part, and select_item collects the selected text. That
// way the text is ready for Ctrl+C without going back over the panel.

ui_select_destroy :: proc(env: ^core.Env) {
	strings.builder_destroy(&env.select.text)
}

// has_selection is whether any text in `panel` is selected.
has_selection :: proc(s: ^core.Selection, panel: core.Select_Panel) -> bool {
	return s.panel == panel && s.anchor != s.focus
}

// select_begin starts a panel's selectable text, inside mu.begin_panel.
select_begin :: proc(env: ^core.Env, panel: core.Select_Panel) {
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
select_end :: proc(env: ^core.Env) {
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
		set_clipboard(nil, strings.to_string(s.text))
	}
}

// select_item adds an item's selected text, if any, to what Ctrl+C copies.
// Call it once per item, in order.
select_item :: proc(env: ^core.Env, item: i64, text: string) {
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

// select_line handles one line of an item as it is drawn: text[start:end] at
// `pos`, in `font` (the style's if nil). It paints the selected part of the
// line (so call it before drawing the text) and works out whether the pointer
// is on the line or past it, which decides where a press or a drag lands.
select_line :: proc(
	env: ^core.Env,
	item: i64,
	text: string,
	start, end: int,
	pos: mu.Vec2,
	rich: ^Rich = nil,
	font: mu.Font = nil,
) {
	ctx := &env.ctx
	s := &env.select
	font := font if font != nil else ctx.style.font
	h := ctx.text_height(font)
	mouse := ctx.mouse_pos

	// A press or drag lands on the line the pointer is on or, failing that,
	// the last line above it, at the end of that line if the pointer is below
	// it. Above every line it lands at the start of the first line.
	if mouse.y >= pos.y {
		if mouse.y < pos.y + h {
			s.hit = {item, offset_at(ctx, font, text, start, end, mouse.x - pos.x, rich)}
			width := span_width(ctx, font, text, start, end, rich)
			if mouse.x >= pos.x &&
			   mouse.x < pos.x + width &&
			   mu.mouse_over(ctx, {pos.x, pos.y, width, h}) {
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
	// Both edges are measured from the start of the line. Widths are whole
	// pixels, rounded up, so the width of text[a:b] by itself can differ by a
	// pixel from the distance between the two edges, and the far edge would
	// shift around as the near one moved.
	x0 := pos.x + span_width(ctx, font, text, start, a, rich)
	x1 := pos.x + span_width(ctx, font, text, start, b, rich)
	mu.draw_rect(ctx, {x0, pos.y, x1 - x0, h}, theme.selection)
}

// selected_range is the part of an item's text (`length` bytes long) that is
// selected in the panel being drawn.
@(private = "file")
selected_range :: proc(s: ^core.Selection, item: i64, length: int) -> (lo, hi: int, ok: bool) {
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

// span_width is how wide text[a:b] is drawn: in `font`, or in its runs' faces
// for a message's text (`rich`, ui/rich_text.odin).
span_width :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	a, b: int,
	rich: ^Rich = nil,
) -> i32 {
	if rich != nil {
		return rich_width(ctx, rich, a, b)
	}
	return ctx.text_width(font, text[a:b])
}

// offset_at is the position in text[start:end] nearest to `x` pixels from its
// start, between two characters.
offset_at :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	start, end: int,
	x: i32,
	rich: ^Rich = nil,
) -> int {
	// Each character's edges are where the text up to that character ends, as
	// select_line paints them. Adding up the characters' own widths instead
	// would also add up their rounding and end up further left the longer the
	// line is.
	left: i32
	for ch, i in text[start:end] {
		next := start + i + utf8.rune_size(ch)
		right := span_width(ctx, font, text, start, next, rich)
		if x < (left + right) / 2 {
			return start + i
		}
		left = right
	}
	return end
}
