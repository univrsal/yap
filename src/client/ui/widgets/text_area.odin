package widgets

import "client:ui/core"
import txt "client:ui/text"
import "core:strings"
import textedit "core:text/edit"
import mu "vendor:microui"

import "client:platform"

// A text area is the box that messages are written in: a text box over several
// lines. Its text wraps the way the chat wraps messages (txt.wrap_line), it grows
// one line at a time up to txt.AREA_MAX_LINES and scrolls beyond that, and
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
// The box's height is worked out before it is laid out (txt.area_height), so
// the rows above can make room. It is based on the width the text had in the
// previous frame, and a frame whose lines don't fit the box it got asks for
// another frame.
//
// A text area can be at least a number of lines tall (min_lines), and keep a
// strip along its bottom (footer) free of text, for buttons that are laid out
// over it (the composer's, see composer_buttons). Pressing in the strip doesn't
// move the caret.

// area_vertical is the place on the line above (`down` false) or below the
// one `at` is on, nearest to `x` pixels along it. Past the first line it is
// the start, and past the last line the end.
area_vertical :: proc(
	ctx: ^mu.Context,
	font: mu.Font,
	text: string,
	lines: []txt.Area_Line,
	at: int,
	x: i32,
	down: bool,
) -> int {
	i := txt.area_line_of(lines, at) + (1 if down else -1)
	if i < 0 {
		return 0
	}
	if i >= len(lines) {
		return len(text)
	}
	l := lines[i]
	return txt.offset_at(ctx, font, text, l.start, l.stop, x)
}

// text_area lays out a text area in the next layout cell, as tall as
// txt.area_height said, with its text in ctx.style.font. Like a text box, it
// returns CHANGE when the text changed and SUBMIT on Enter (and releases the
// focus then).
//
// In a web build the page's own text field draws and edits the text instead,
// over the box (ui/widgets/field_web.odin), unless something covers it.
text_area :: proc(env: ^core.Env, buf: []u8, textlen: ^int, area: ^txt.Area) -> (res: mu.Result_Set) {
	ctx := &env.ctx
	id := mu.get_id(ctx, uintptr(&buf[0]))
	r := mu.layout_next(ctx)
	live := false
	when platform.WEB {
		field_take(env, id, buf, textlen, area)
		live = area.field.live
		append(
			&env.text_boxes,
			core.Text_Box{id, mu.intersect_rects(r, mu.get_clip_rect(ctx)), true, live},
		)
	}
	if area.field.changed {
		area.field.changed = false
		res += {.CHANGE}
	}
	mu.update_control(ctx, id, r, {.HOLD_FOCUS})
	core.nav_control(ctx, id, r, textlen^)
	tr := txt.area_text_rect(r, area)
	if .LEFT in ctx.mouse_pressed_bits {
		area.footer_press = area.footer > 0 && mu.mouse_over(ctx, r) && !mu.mouse_over(ctx, tr)
	} else if .LEFT not_in ctx.mouse_down_bits {
		area.footer_press = false
	}
	if ctx.hover_id == id && mu.mouse_over(ctx, tr) {
		env.select.over_text = true // shows an I-beam over it (draw_frame)
	}

	font := ctx.style.font
	lh := ctx.text_height(font)
	single := txt.area_single(ctx, font)
	top := (single - lh) / 2 // from the box's top to its first line's top
	rows := clamp((tr.h - (single - lh)) / lh, 1, txt.AREA_MAX_LINES)
	full := max(r.w - 2 * ctx.style.padding, 1)
	if area.width != full {
		// The next frame's height is worked out at this width.
		area.width = full
		core.redraw_now(env)
	}
	// Beyond the maximum number of lines, a scrollbar takes its width from
	// the text's. (The box is as tall either way.)
	bar_w := ctx.style.scrollbar_size
	width := full
	if len(txt.area_lines(ctx, font, string(buf[:textlen^]), full)) > txt.AREA_MAX_LINES {
		width = max(full - bar_w, 1)
	}
	s := &ctx.textbox_state
	focused := ctx.focus_id == id

	if focused && !live {
		for key in ([?]core.Extra_Key{.Undo, .Redo}) {
			if key not_in env.keys {
				continue
			}
			env.keys -= {key}
			text := string(buf[:textlen^])
			step: txt.History_Step
			ok: bool
			if key == .Undo {
				step, ok = txt.history_undo(&area.history, text)
			} else {
				step, ok = txt.history_redo(&area.history, text)
			}
			if !ok || len(step.text) > len(buf) {
				continue
			}
			textlen^ = copy(buf, step.text)
			s.id = u64(id)
			s.selection = step.sel
			res += {.CHANGE}
		}
	}

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

		// The page's field does the editing itself.
		if !live {
			if strings.builder_len(ctx.text_input) > 0 {
				if textedit.input_text(s, strings.to_string(ctx.text_input)) > 0 {
					edited(&res, textlen, &builder)
				}
			}
			// A new line: Shift+Enter, or Enter on a phone's keyboard.
			if (.RETURN in ctx.key_pressed_bits && shift) || .Newline in env.keys {
				ctx.key_pressed_bits -= {.RETURN}
				env.keys -= {.Newline}
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
			lines := txt.area_lines(ctx, font, text, width)
			l := lines[txt.area_line_of(lines, s.selection[0])]
			s.line_start, s.line_end = l.start, l.stop
			if .HOME in ctx.key_pressed_bits {
				move(s, .Start if ctrl else .Soft_Line_Start, shift)
			}
			if .END in ctx.key_pressed_bits {
				move(s, .End if ctrl else .Soft_Line_End, shift)
			}
			if .Up in env.keys || .Down in env.keys {
				down := .Down in env.keys
				env.keys -= {.Up, .Down}
				at := s.selection[0]
				x := area.vert_x
				if area.vert_at != at {
					x = txt.area_x(ctx, font, text, lines[txt.area_line_of(lines, at)], at)
				}
				to := area_vertical(ctx, font, text, lines, at, x, down)
				s.selection[0] = to
				if !shift {
					s.selection[1] = to
				}
				area.vert_at, area.vert_x = to, x
			}

			// Pressing or dragging puts the caret where the pointer is: on the
			// line it is over, or the first or last line if it is past them. Not
			// on the scrollbar, though.
			on_bar :=
				.LEFT in ctx.mouse_pressed_bits && area.bar.w > 0 && mu.mouse_over(ctx, area.bar)
			if .LEFT in ctx.mouse_down_bits && !area.dragging && !on_bar && !area.footer_press {
				i := clamp(
					(ctx.mouse_pos.y - r.y - top + area.scroll) / lh,
					0,
					i32(len(lines) - 1),
				)
				pl := lines[i]
				at := txt.offset_at(
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
		if .RETURN in ctx.key_pressed_bits {
			mu.set_focus(ctx, 0)
			res += {.SUBMIT}
		}
	}

	text := string(buf[:textlen^])
	when !platform.WEB {
		txt.history_note_now(&area.history, text, s.selection if focused else area.history.now.sel)
	}
	lines := txt.area_lines(ctx, font, text, width)
	n := len(lines)
	if live && area.field.lines > 0 {
		n = area.field.lines
	}
	if i32(txt.area_rows(area, n)) != rows {
		// The box is the height that the text had before this frame's typing.
		core.redraw_now(env)
	}
	when platform.WEB {
		field_place(env, id, text, area, tr, top, single - lh - top, focused)
	}
	if live {
		// Only the box: the page's field is over it, with the text.
		mu.draw_control_frame(ctx, id, r, .BASE, {})
		area.bar = {}
		area.had_focus = focused
		return
	}

	// Scrolling: to the caret when it moved, the text changed or the box has
	// just taken the focus, otherwise by the wheel over the box. It scrolls as
	// if the box were already as tall as it is about to be: while it grows to
	// fit a new line, that line is cut off for a frame instead of the text
	// scrolling and a scrollbar showing for one.
	view := max(rows, i32(min(len(lines), txt.AREA_MAX_LINES)))
	most := max(i32(len(lines)) * lh - view * lh, 0)
	if focused && (s.selection != area.last_sel || textlen^ != area.last_len || !area.had_focus) {
		y := i32(txt.area_line_of(lines, s.selection[0])) * lh
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
	caret := txt.area_line_of(lines, s.selection[0])
	for l, i in lines {
		y := r.y + top + i32(i) * lh - area.scroll
		if y + lh <= tr.y || y >= tr.y + tr.h {
			continue
		}
		if focused && lo != hi && lo <= l.stop && hi >= l.start {
			a := txt.area_x(ctx, font, text, l, max(lo, l.start))
			b := txt.area_x(ctx, font, text, l, min(hi, l.stop))
			// Past the end of the line: its newline is selected too.
			if hi > l.stop {
				b += ctx.text_width(font, " ")
			}
			mu.draw_rect(ctx, {x0 + a, y, b - a, lh}, ctx.style.colors[.SELECTION_BG])
		}
		mu.draw_text(ctx, font, text[l.start:l.end], {x0, y}, color)
		if focused && i == caret {
			x := min(txt.area_x(ctx, font, text, l, s.selection[0]), width)
			mu.draw_rect(ctx, {x0 + x, y, 1, lh}, color)
		}
	}
	if area.bar.w > 0 {
		// Thin like the panels' scrollbars, but always shown while there is one.
		hovered := area.dragging || mu.mouse_over(ctx, area.bar)
		core.scrollbar_draw(ctx, area.bar, .SCROLL_BASE, 1, hovered)
		core.scrollbar_draw(ctx, thumb, .SCROLL_THUMB, 1, hovered)
	}
	return
}
