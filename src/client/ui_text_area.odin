package client

import "core:strings"
import textedit "core:text/edit"
import mu "vendor:microui"

import "client:platform"

// A text area is the box that messages are written in: a text box over several
// lines. Its text wraps the way the chat wraps messages (wrap_line), it grows
// one line at a time up to TEXT_AREA_MAX_LINES and scrolls beyond that, and
// Shift+Enter starts a new line while Enter submits, as in a text box.
//
// It is microui's text box (textbox_raw) taken over line by line: the same id
// for the same buffer and the same core:text/edit state in the context, so
// everything that works on a text box from outside (focus_at, the completion
// list, the composer's keys, pasting) works on this too. On top of that, Up
// and Down (the UI's own keys, ui.keys) move between lines and keep to the
// column they started in, Home and End go to the ends of the line (with Ctrl,
// of the text), and the pointer lands on the line it is over.
//
// The box's height is worked out before it is laid out (text_area_height), so
// the rows above can make room. It is based on the width the text had in the
// previous frame, and a frame whose lines don't fit the box it got asks for
// another frame.
//
// A text area can be at least a number of lines tall (min_lines), and keep a
// strip along its bottom (footer) free of text, for buttons that are laid out
// over it (the composer's, see composer_buttons). Pressing in the strip doesn't
// move the caret.

// The most lines a text area grows to. Beyond that it scrolls.
TEXT_AREA_MAX_LINES :: 10

// What a text area keeps between frames.
Text_Area :: struct {
	width:     i32, // the text's width in the last frame, for working out the height
	scroll:    i32, // pixels of the text above the box's top
	// Up and Down keep to the column they started in: where they left the
	// caret, and the x position they were aiming for.
	vert_at:   int,
	vert_x:    i32,
	// The selection and length in the last frame. When either changes, the
	// box scrolls to the caret.
	last_sel:  [2]int,
	last_len:  int,
	// Its scrollbar, when there is more text than it shows: where it was in
	// the last frame (zero: none), and while its thumb is dragged, how far
	// down the thumb it was grabbed.
	bar:       mu.Rect,
	dragging:  bool,
	drag_at:   i32,
	// Whether the message is shown as it will look instead (the composer's
	// eye, preview_button).
	preview:   bool,
	had_focus: bool, // in the last frame
	// Set by its owner before it is measured and laid out: how many lines tall
	// it is at least (0 or 1 for one), and how tall the strip at its bottom is.
	min_lines: int,
	footer:    i32,
	// A press in the footer, which the caret ignores until it is released.
	footer_press: bool,
}

// One line of a text area's text: text[start:end] is drawn, and the caret is
// on it from `start` up to `stop` (where the next line starts, or before the
// newline that ends it, or the end of the text).
Area_Line :: struct {
	start, end, stop: int,
}

// area_lines lays `text` out in lines `width` wide. Every place in the text is
// on exactly one line: a place where a wrap broke the text is on the line that
// starts there. There is always at least one line, and a text ending in a
// newline ends in an empty line for the caret to go to.
area_lines :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	width: i32,
	allocator := context.temp_allocator,
) -> []Area_Line {
	lines := make([dynamic]Area_Line, allocator)
	at := 0
	for at < len(text) {
		end, next := wrap_line(ctx, font, text[at:], width)
		stop := at + next - 1
		if at + next == len(text) && text[len(text) - 1] != '\n' {
			stop = len(text)
		}
		append(&lines, Area_Line{at, at + end, stop})
		at += next
	}
	if len(text) == 0 || text[len(text) - 1] == '\n' {
		append(&lines, Area_Line{len(text), len(text), len(text)})
	}
	return lines[:]
}

// area_line_of is the line that the place `at` is on.
area_line_of :: proc(lines: []Area_Line, at: int) -> int {
	for l, i in lines {
		if at <= l.stop {
			return i
		}
	}
	return len(lines) - 1
}

// area_x is how far along its line the place `at` is, in pixels.
area_x :: proc(ctx: ^mu.Context, font: mu.Font, text: string, l: Area_Line, at: int) -> i32 {
	return ctx.text_width(font, text[l.start:clamp(at, l.start, l.stop)])
}

// area_vertical is the place on the line above (`down` false) or below the
// one `at` is on, nearest to `x` pixels along it. Past the first line it is
// the start, and past the last line the end.
area_vertical :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	lines: []Area_Line,
	at: int,
	x: i32,
	down: bool,
) -> int {
	i := area_line_of(lines, at) + (1 if down else -1)
	if i < 0 {
		return 0
	}
	if i >= len(lines) {
		return len(text)
	}
	l := lines[i]
	return offset_at(ctx, font, text, l.start, l.stop, x)
}

// text_area_single is how tall a text area of one line is: a control's
// height, or more for a bigger font. Each additional line adds a line's height.
text_area_single :: proc(ctx: ^mu.Context, font: mu.Font) -> i32 {
	return max(ctx.style.size.y + 2 * ctx.style.padding, ctx.text_height(font) + 4)
}

// text_area_height is how tall the text area for `text` is, in `font` (which
// ctx.style.font has to be when it is laid out).
text_area_height :: proc(ctx: ^mu.Context, font: mu.Font, text: string, area: ^Text_Area) -> i32 {
	n := 1
	if area.width > 0 {
		n = len(area_lines(ctx, font, text, area.width))
	}
	return(
		text_area_single(ctx, font) +
		i32(area_rows(area, n) - 1) * ctx.text_height(font) +
		area.footer \
	)
}

// area_rows is how many lines tall a text area with `n` lines of text is.
@(private = "file")
area_rows :: proc(area: ^Text_Area, n: int) -> int {
	return max(min(n, TEXT_AREA_MAX_LINES), area.min_lines, 1)
}

// text_area_text_rect is the part of a text area's rect that the text is in:
// all of it except the footer.
text_area_text_rect :: proc(r: mu.Rect, area: ^Text_Area) -> mu.Rect {
	return {r.x, r.y, r.w, max(r.h - area.footer, 1)}
}

// text_area lays out a text area in the next layout cell, as tall as
// text_area_height said, with its text in ctx.style.font. Like a text box, it
// returns CHANGE when the text changed and SUBMIT on Enter (and releases the
// focus then).
text_area :: proc(ui: ^UI, buf: []u8, textlen: ^int, area: ^Text_Area) -> (res: mu.Result_Set) {
	ctx := &ui.ctx
	id := mu.get_id(ctx, uintptr(&buf[0]))
	r := mu.layout_next(ctx)
	when platform.WEB {
		append(&ui.text_boxes, Text_Box{id, mu.intersect_rects(r, mu.get_clip_rect(ctx)), true})
	}
	mu.update_control(ctx, id, r, {.HOLD_FOCUS})
	tr := text_area_text_rect(r, area)
	if .LEFT in ctx.mouse_pressed_bits {
		area.footer_press = area.footer > 0 && mu.mouse_over(ctx, r) && !mu.mouse_over(ctx, tr)
	} else if .LEFT not_in ctx.mouse_down_bits {
		area.footer_press = false
	}
	if ctx.hover_id == id && mu.mouse_over(ctx, tr) {
		ui.select.over_text = true // shows an I-beam over it (draw_frame)
	}

	font := ctx.style.font
	lh := ctx.text_height(font)
	single := text_area_single(ctx, font)
	top := (single - lh) / 2 // from the box's top to its first line's top
	rows := clamp((tr.h - (single - lh)) / lh, 1, TEXT_AREA_MAX_LINES)
	full := max(r.w - 2 * ctx.style.padding, 1)
	if area.width != full {
		// The next frame's height is worked out at this width.
		area.width = full
		ui_redraw(ui)
	}
	// Beyond the maximum number of lines, a scrollbar takes its width from
	// the text's. (The box is as tall either way.)
	bar_w := ctx.style.scrollbar_size
	width := full
	if len(area_lines(ctx, font, string(buf[:textlen^]), full)) > TEXT_AREA_MAX_LINES {
		width = max(full - bar_w, 1)
	}
	s := &ctx.textbox_state
	focused := ctx.focus_id == id

	if focused {
		// The same as microui's text box: a builder on our buffer, and the
		// selection is kept while the focus stays.
		builder := strings.builder_from_bytes(buf)
		non_zero_resize(&builder.buf, textlen^)
		s.builder = &builder
		if s.id != u64(id) {
			s.id = u64(id)
			s.selection = {}
		}
		if s.selection[0] > textlen^ || s.selection[1] > textlen^ {
			s.selection = {}
		}
		edited :: proc(res: ^mu.Result_Set, textlen: ^int, builder: ^strings.Builder) {
			textlen^ = strings.builder_len(builder^)
			res^ += {.CHANGE}
		}
		ctrl := .CTRL in ctx.key_down_bits && .ALT not_in ctx.key_down_bits
		shift := .SHIFT in ctx.key_down_bits

		if strings.builder_len(ctx.text_input) > 0 {
			if textedit.input_text(s, strings.to_string(ctx.text_input)) > 0 {
				edited(&res, textlen, &builder)
			}
		}
		// A new line: Shift+Enter, or Enter on a phone's keyboard.
		if (.RETURN in ctx.key_pressed_bits && shift) || .Newline in ui.keys {
			ctx.key_pressed_bits -= {.RETURN}
			ui.keys -= {.Newline}
			if textedit.input_text(s, "\n") > 0 {
				edited(&res, textlen, &builder)
			}
		}
		if .A in ctx.key_pressed_bits && ctrl {
			s.selection = {textlen^, 0}
		}
		if .X in ctx.key_pressed_bits && ctrl && textedit.cut(s) {
			edited(&res, textlen, &builder)
		}
		if .C in ctx.key_pressed_bits && ctrl {
			textedit.copy(s)
		}
		if .V in ctx.key_pressed_bits && ctrl && textedit.paste(s) {
			edited(&res, textlen, &builder)
		}
		if .BACKSPACE in ctx.key_pressed_bits && textlen^ > 0 {
			textedit.delete_to(s, .Word_Left if ctrl else .Left)
			edited(&res, textlen, &builder)
		}
		if .DELETE in ctx.key_pressed_bits && textlen^ > 0 {
			textedit.delete_to(s, .Word_Right if ctrl else .Right)
			edited(&res, textlen, &builder)
		}
		move :: proc(s: ^textedit.State, t: textedit.Translation, shift: bool) {
			if shift {
				textedit.select_to(s, t)
			} else {
				textedit.move_to(s, t)
			}
		}
		if .LEFT in ctx.key_pressed_bits {
			move(s, .Word_Left if ctrl else .Left, shift)
		}
		if .RIGHT in ctx.key_pressed_bits {
			move(s, .Word_Right if ctrl else .Right, shift)
		}

		// What is left needs the lines, as the text is now.
		text := string(buf[:textlen^])
		lines := area_lines(ctx, font, text, width)
		l := lines[area_line_of(lines, s.selection[0])]
		s.line_start, s.line_end = l.start, l.stop
		if .HOME in ctx.key_pressed_bits {
			move(s, .Start if ctrl else .Soft_Line_Start, shift)
		}
		if .END in ctx.key_pressed_bits {
			move(s, .End if ctrl else .Soft_Line_End, shift)
		}
		if .Up in ui.keys || .Down in ui.keys {
			down := .Down in ui.keys
			ui.keys -= {.Up, .Down}
			at := s.selection[0]
			x := area.vert_x
			if area.vert_at != at {
				x = area_x(ctx, font, text, lines[area_line_of(lines, at)], at)
			}
			to := area_vertical(ctx, font, text, lines, at, x, down)
			s.selection[0] = to
			if !shift {
				s.selection[1] = to
			}
			area.vert_at, area.vert_x = to, x
		}
		if .RETURN in ctx.key_pressed_bits {
			mu.set_focus(ctx, 0)
			res += {.SUBMIT}
		}

		// Pressing or dragging puts the caret where the pointer is: on the
		// line it is over, or the first or last line if it is past them. Not
		// on the scrollbar, though.
		on_bar := .LEFT in ctx.mouse_pressed_bits && area.bar.w > 0 && mu.mouse_over(ctx, area.bar)
		if .LEFT in ctx.mouse_down_bits && !area.dragging && !on_bar && !area.footer_press {
			i := clamp((ctx.mouse_pos.y - r.y - top + area.scroll) / lh, 0, i32(len(lines) - 1))
			pl := lines[i]
			at := offset_at(
				ctx,
				font,
				text,
				pl.start,
				pl.stop,
				ctx.mouse_pos.x - r.x - ctx.style.padding,
			)
			s.selection[0] = at
			if .LEFT in ctx.mouse_pressed_bits && !shift {
				s.selection[1] = at
			}
		}
	}

	text := string(buf[:textlen^])
	lines := area_lines(ctx, font, text, width)
	if i32(area_rows(area, len(lines))) != rows {
		// The box is the height that the text had before this frame's typing.
		ui_redraw(ui)
	}

	// Scrolling: to the caret when it moved, the text changed or the box has
	// just taken the focus, otherwise by the wheel over the box. It scrolls as
	// if the box were already as tall as it is about to be: while it grows to
	// fit a new line, that line is cut off for a frame instead of the text
	// scrolling and a scrollbar showing for one.
	view := max(rows, i32(min(len(lines), TEXT_AREA_MAX_LINES)))
	most := max(i32(len(lines)) * lh - view * lh, 0)
	if focused && (s.selection != area.last_sel || textlen^ != area.last_len || !area.had_focus) {
		y := i32(area_line_of(lines, s.selection[0])) * lh
		if y < area.scroll {
			area.scroll = y
		} else if y + lh > area.scroll + view * lh {
			area.scroll = y + lh - view * lh
		}
	} else if most > 0 && ctx.scroll_delta.y != 0 && mu.mouse_over(ctx, tr) {
		area.scroll += ctx.scroll_delta.y
		ctx.scroll_delta.y = 0 // not for the panel behind
	}
	area.scroll = clamp(area.scroll, 0, most)
	if focused {
		area.last_sel, area.last_len = s.selection, textlen^
	}
	area.had_focus = focused
	// The scrollbar: pressing on its thumb drags it, and pressing on the rest
	// of the bar makes the thumb's middle jump there and be dragged.
	area.bar = {}
	thumb: mu.Rect
	if most > 0 {
		area.bar = {tr.x + tr.w - bar_w, tr.y, bar_w, tr.h}
		thumb_h := max(tr.h * view / i32(len(lines)), bar_w)
		span := max(tr.h - thumb_h, 1)
		thumb = {area.bar.x, r.y + span * area.scroll / most, bar_w, thumb_h}
		if .LEFT in ctx.mouse_pressed_bits && mu.mouse_over(ctx, area.bar) {
			area.dragging = true
			area.drag_at = ctx.mouse_pos.y - thumb.y if mu.mouse_over(ctx, thumb) else thumb_h / 2
		}
		if area.dragging && .LEFT in ctx.mouse_down_bits {
			area.scroll = clamp((ctx.mouse_pos.y - area.drag_at - r.y) * most / span, 0, most)
			thumb.y = r.y + span * area.scroll / most
		}
	}
	if .LEFT not_in ctx.mouse_down_bits || most == 0 {
		area.dragging = false
	}

	mu.draw_control_frame(ctx, id, r, .BASE, {})
	mu.push_clip_rect(ctx, tr)
	defer mu.pop_clip_rect(ctx)
	color := ctx.style.colors[.TEXT]
	x0 := r.x + ctx.style.padding
	lo, hi := s.selection[0], s.selection[1]
	if lo > hi {
		lo, hi = hi, lo
	}
	caret := area_line_of(lines, s.selection[0])
	for l, i in lines {
		y := r.y + top + i32(i) * lh - area.scroll
		if y + lh <= tr.y || y >= tr.y + tr.h {
			continue
		}
		if focused && lo != hi && lo <= l.stop && hi >= l.start {
			a := area_x(ctx, font, text, l, max(lo, l.start))
			b := area_x(ctx, font, text, l, min(hi, l.stop))
			// Past the end of the line: its newline is selected too.
			if hi > l.stop {
				b += ctx.text_width(font, " ")
			}
			mu.draw_rect(ctx, {x0 + a, y, b - a, lh}, ctx.style.colors[.SELECTION_BG])
		}
		mu.draw_text(ctx, font, text[l.start:l.end], {x0, y}, color)
		if focused && i == caret {
			x := min(area_x(ctx, font, text, l, s.selection[0]), width)
			mu.draw_rect(ctx, {x0 + x, y, 1, lh}, color)
		}
	}
	if area.bar.w > 0 {
		// Rounded like the panels' scrollbars (draw_frame).
		ctx.draw_frame(ctx, area.bar, .SCROLL_BASE)
		ctx.draw_frame(ctx, thumb, .SCROLL_THUMB)
	}
	return
}
