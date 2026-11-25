package client

import "core:math"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:render"

// Carets, clicks and selections in lines whose characters aren't drawn in
// the order of the text: lines with right-to-left text, which the renderer
// shapes and puts in visual order (render/shape_native.odin). Everywhere
// else a place in a line is as far along as the text before it is wide, and
// the text area, text boxes and selecting go by that as before; for such a
// line they go by where each character is drawn (line_spans) instead.
//
//   - Each place in the line has one spot where its caret is drawn: the
//     line's start and end at its edges (the start on the left of a
//     left-to-right line and the end on its right, the other way round in
//     a right-to-left one), any other place at the trailing edge of the
//     character before it (its right edge if it is left to right, its left
//     edge if it is right to left), so the caret stays with what was just
//     typed.
//   - A click lands on the place drawn nearest to it.
//   - A selection is the characters it spans, which may be several pieces
//     of the line.
//   - A cluster (a conjunct, a letter with marks) is one place to stop over:
//     the caret has no stop, and a click no place, inside it.
//   - Left and Right move the caret to the place drawn next to the left or
//     right on the screen (bidi_step), not to the next character in the
//     text.

// line_spans returns where the characters of the line text[start:end] are
// drawn, in `font` or in its runs' faces for a message's text (`rich`), with
// x from the line's start. It returns shaped false, and nothing, for a line
// that is drawn in the order of its text. In the temp allocator.
line_spans :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	start, end: int,
	rich: ^Rich = nil,
) -> (
	spans: []render.Char_Span,
	shaped: bool,
) {
	if rich == nil || len(rich.runs) == 0 {
		piece := text[start:end]
		if !render.text_is_shaped(font, piece) {
			return
		}
		spans = render.text_spans(font, piece)
		for &s in spans {
			s.at += start
		}
		return spans, true
	}
	// Run by run, each in its own face and shaped on its own, as
	// rich_width measures and the message draws them.
	out := make([dynamic]render.Char_Span, context.temp_allocator)
	x: f32
	line_rtl := false
	for i := start; i < end; {
		run := rich.runs[rich_run(rich, i)]
		e := min(end, max(run.end, i + 1))
		f := rich_font(ctx, run.styles)
		piece := text[i:e]
		if render.text_is_shaped(f, piece) {
			piece_spans := render.text_spans(f, piece)
			if !shaped && len(piece_spans) > 0 {
				// The line's direction: that of its first shaped piece.
				line_rtl = piece_spans[0].line_rtl
			}
			shaped = true
			for s in piece_spans {
				append(&out, render.Char_Span{at = s.at + i, x0 = s.x0 + x, x1 = s.x1 + x, rtl = s.rtl, joined = s.joined})
			}
		} else {
			left: f32
			for ch, k in piece {
				right := f32(ctx.text_width(f, piece[:k + utf8.rune_size(ch)]))
				append(&out, render.Char_Span{at = i + k, x0 = x + left, x1 = x + right})
				left = right
			}
		}
		x += f32(ctx.text_width(f, piece))
		i = e
	}
	if !shaped {
		return nil, false
	}
	for &s in out {
		s.line_rtl = line_rtl
	}
	return out[:], true
}

// line_is_rtl returns whether the line text[start:end] is shaped and right to
// left (its first strong character is), which makes it sit against the right
// edge of its column.
line_is_rtl :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	start, end: int,
	rich: ^Rich = nil,
) -> bool {
	spans, shaped := line_spans(ctx, font, text, start, end, rich)
	return shaped && len(spans) > 0 && spans[0].line_rtl
}

// span_end returns where the character of spans[i] ends in the text: where
// the next one starts, or `end`.
@(private = "file")
span_end :: proc(spans: []render.Char_Span, i, end: int) -> int {
	return spans[i + 1].at if i + 1 < len(spans) else end
}

// bidi_caret_x returns where the caret at the place `at` of a line (the text
// from `start` to `end`) is drawn. The line's start and end are at its
// edges: the start on the left of a left-to-right line and the end on its
// right, the other way round in a right-to-left one, which is where text
// typed there in the line's direction goes. Any other place is drawn at the
// trailing edge of the character before it, so the caret stays with what
// was just typed.
bidi_caret_x :: proc(spans: []render.Char_Span, start, end: int, at: int) -> f32 {
	if len(spans) == 0 {
		return 0
	}
	left, right := spans[0].x0, spans[0].x1
	for s in spans {
		left, right = min(left, s.x0), max(right, s.x1)
	}
	rtl := spans[0].line_rtl
	if at >= end {
		return left if rtl else right
	}
	if at <= start {
		return right if rtl else left
	}
	for s, i in spans {
		if span_end(spans, i, end) == at {
			return s.x0 if s.rtl else s.x1
		}
	}
	return right
}

// The places of a line, each with where its caret is drawn.
@(private = "file")
Caret_Stop :: struct {
	at: int,
	x:  f32,
}

@(private = "file")
caret_stops :: proc(spans: []render.Char_Span, start, end: int) -> []Caret_Stop {
	stops := make([dynamic]Caret_Stop, 0, len(spans) + 1, context.temp_allocator)
	append(&stops, Caret_Stop{start, bidi_caret_x(spans, start, end, start)})
	for _, i in spans {
		// Not in front of a character that continues a cluster.
		if i + 1 < len(spans) && spans[i + 1].joined {
			continue
		}
		at := span_end(spans, i, end)
		append(&stops, Caret_Stop{at, bidi_caret_x(spans, start, end, at)})
	}
	return stops[:]
}

// bidi_offset_at returns the place in a line (from `start` to `end`) whose
// caret is drawn nearest to `x`, so that a click puts the caret right where
// it was clicked.
bidi_offset_at :: proc(spans: []render.Char_Span, start, end: int, x: f32) -> int {
	best, best_d := end, max(f32)
	for s in caret_stops(spans, start, end) {
		if d := abs(s.x - x); d < best_d {
			best, best_d = s.at, d
		}
	}
	return best
}

// bidi_ranges returns the stretches of a line that the characters from `lo`
// up to `hi` are drawn over, left to right. In the temp allocator.
bidi_ranges :: proc(spans: []render.Char_Span, lo, hi: int) -> [][2]f32 {
	out := make([dynamic][2]f32, context.temp_allocator)
	for s in spans {
		if s.at < lo || s.at >= hi || s.x1 <= s.x0 {
			continue
		}
		append(&out, [2]f32{s.x0, s.x1})
	}
	// Sorted, and those that touch joined.
	for i in 1 ..< len(out) {
		for j := i; j > 0 && out[j][0] < out[j - 1][0]; j -= 1 {
			out[j], out[j - 1] = out[j - 1], out[j]
		}
	}
	merged := make([dynamic][2]f32, context.temp_allocator)
	for r in out {
		if n := len(merged); n > 0 && r[0] <= merged[n - 1][1] + 0.5 {
			merged[n - 1][1] = max(merged[n - 1][1], r[1])
		} else {
			append(&merged, r)
		}
	}
	return merged[:]
}

// bidi_step returns the place the caret goes to from `at` when it moves to
// the right (or left) in a line: the place drawn nearest to it on that side.
// It isn't ok at the line's right (left) end. With the line's `words` (its
// text), it goes to the nearest place that starts or ends a word instead.
bidi_step :: proc(
	spans: []render.Char_Span,
	start, end, at: int,
	right: bool,
	words := "",
) -> (
	to: int,
	ok: bool,
) {
	x := bidi_caret_x(spans, start, end, at)
	best: f32
	for s in caret_stops(spans, start, end) {
		if s.at == at || (words != "" && !word_boundary(words, start, end, s.at)) {
			continue
		}
		d := s.x - x if right else x - s.x
		if d > 0.5 && (!ok || d < best) {
			best, to, ok = d, s.at, true
		}
	}
	return
}

// word_boundary returns whether the place `at` of text, a line from `start`
// to `end`, is the line's start or end or has a word (area_word's classes)
// on one side and not on the other.
@(private = "file")
word_boundary :: proc(text: string, start, end, at: int) -> bool {
	if at <= start || at >= end {
		return true
	}
	before := char_class(text[at - 1]) == .Word
	after := char_class(text[at]) == .Word
	return before != after
}

// round_px rounds a position along a line to whole logical pixels.
round_px :: proc(x: f32) -> i32 {
	return i32(math.round(x))
}
