package ui

import "core"
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

	lo, hi, ok := core.selected_range(s, item, len(text))
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
	mu.draw_rect(ctx, {x0, pos.y, x1 - x0, h}, core.theme.selection)
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
