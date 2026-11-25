package client

import "client:platform"
import "client:render"
import "core:strings"
import textedit "core:text/edit"
import mu "vendor:microui"

// Every text box goes through text_box, which is mu.textbox (text_box_raw:
// microui's, with right-to-left text placed where it is drawn) plus a note of
// where it was laid out.
//
// A phone shows its keyboard only when one of the page's own text fields has
// the focus, and only if that happens while the tap is still being handled.
// The page can't wait a frame to see whether the tap landed on a text box. So
// each frame notes where its text boxes are, and the page asks about the tap
// there and then (see ui_touch_web.odin). A desktop build notes nothing.

Text_Box :: struct {
	id:        mu.Id,
	rect:      mu.Rect, // as visible: clipped to its container
	multiline: bool, // a text area (ui_text_area.odin), where Enter starts a line
	// The page's own text field is over it (ui_field_web.odin), so a tap
	// lands there and brings the keyboard up itself.
	live:      bool,
}

text_box :: proc(ui: ^UI, buf: []u8, textlen: ^int, opt := mu.Options{}, plain := false) -> mu.Result_Set {
	ctx := &ui.ctx
	// The same id mu.textbox would use, so ctx.last_id names the box
	// afterwards as it did.
	id := mu.get_id(ctx, uintptr(&buf[0]))
	r := mu.layout_next(ctx)
	when platform.WEB {
		append(
			&ui.text_boxes,
			Text_Box{id, mu.intersect_rects(r, mu.get_clip_rect(ctx)), false, false},
		)
	}
	res := text_box_raw(ctx, buf, textlen, id, r, opt, plain)
	nav_control(ctx, id, r, textlen^)
	if ctx.hover_id == id {
		ui.select.over_text = true // shows an I-beam over it (draw_frame)
	}
	return res
}

// password_box is a text box that shows an asterisk for every byte of its
// text, and won't copy or cut it.
//
// microui's text box has no such option, so the masking is done around it.
// While the box runs, the text is measured as asterisks (which is what the
// cursor, the selection and clicks are based on), and afterwards the text that
// it drew is overwritten with asterisks in microui's command list, before
// anything renders it.
password_box :: proc(ui: ^UI, buf: []u8, textlen: ^int, opt := mu.Options{}) -> mu.Result_Set {
	ctx := &ui.ctx
	if ctx.focus_id == mu.get_id(ctx, uintptr(&buf[0])) {
		ctx.key_pressed_bits -= {.C, .X}
	}

	text_width := ctx.text_width
	ctx.text_width = proc(font: mu.Font, text: string) -> i32 {
		return i32(len(text)) * render.ui_text_width(font, "*")
	}
	first := ctx.command_list.idx
	res := text_box(ui, buf, textlen, opt, plain = true)
	ctx.text_width = text_width

	for at := first; at < ctx.command_list.idx; {
		cmd := (^mu.Command)(&ctx.command_list.items[at])
		if text, ok := cmd.variant.(^mu.Command_Text); ok {
			for i in 0 ..< len(text.str) {
				([^]u8)(raw_data(text.str))[i] = '*'
			}
		}
		at += cmd.size
	}
	return res
}

// focus_at gives the text box `id` the focus, with the cursor `at` bytes into
// its text, so typing continues from text that was put in it.
focus_at :: proc(ctx: ^mu.Context, id: mu.Id, at: int) {
	mu.set_focus(ctx, id)
	ctx.textbox_state.id = u64(id)
	ctx.textbox_state.selection = {at, at}
}

// text_box_raw is microui's text box (mu.textbox_raw), with the caret, clicks,
// Left and Right and the selection placed by where the characters are drawn
// in a line with right-to-left text (ui_bidi.odin). For other text, and with
// `plain` (a password box, whose text is drawn as asterisks), it does what
// microui's does.
@(private = "file")
text_box_raw :: proc(
	ctx: ^mu.Context,
	textbuf: []u8,
	textlen: ^int,
	id: mu.Id,
	r: mu.Rect,
	opt: mu.Options,
	plain: bool,
) -> (
	res: mu.Result_Set,
) {
	mu.update_control(ctx, id, r, opt | {.HOLD_FOCUS})
	font := ctx.style.font
	s := &ctx.textbox_state
	// Where the characters are drawn, when that isn't in the order of the
	// text.
	spans_of :: proc(ctx: ^mu.Context, font: mu.Font, text: string, plain: bool) -> ([]render.Char_Span, bool) {
		if plain {
			return nil, false
		}
		return line_spans(ctx, font, text, 0, len(text))
	}

	if ctx.focus_id == id {
		// A builder on the caller's buffer, as microui's.
		builder := strings.builder_from_bytes(textbuf)
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
		move :: proc(s: ^textedit.State, t: textedit.Translation, shift: bool) {
			if shift {
				textedit.select_to(s, t)
			} else {
				textedit.move_to(s, t)
			}
		}

		if strings.builder_len(ctx.text_input) > 0 {
			if textedit.input_text(s, strings.to_string(ctx.text_input)) > 0 {
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
		for key in ([?]mu.Key{.LEFT, .RIGHT}) {
			if key not_in ctx.key_pressed_bits {
				continue
			}
			right := key == .RIGHT
			// To the next place on the screen in a line with right-to-left
			// text, as in a text area.
			if !ctrl && (shift || s.selection[0] == s.selection[1]) {
				text := string(textbuf[:textlen^])
				if spans, shaped := spans_of(ctx, font, text, plain); shaped {
					if to, ok := bidi_step(spans, 0, len(text), s.selection[0], right); ok {
						s.selection[0] = to
						if !shift {
							s.selection[1] = to
						}
					}
					continue
				}
			}
			if right {
				move(s, .Word_Right if ctrl else .Right, shift)
			} else {
				move(s, .Word_Left if ctrl else .Left, shift)
			}
		}
		if .HOME in ctx.key_pressed_bits {
			move(s, .Start, shift)
		}
		if .END in ctx.key_pressed_bits {
			move(s, .End, shift)
		}
		if .BACKSPACE in ctx.key_pressed_bits && textlen^ > 0 {
			textedit.delete_to(s, .Word_Left if ctrl else .Left)
			edited(&res, textlen, &builder)
		}
		if .DELETE in ctx.key_pressed_bits && textlen^ > 0 {
			textedit.delete_to(s, .Word_Right if ctrl else .Right)
			edited(&res, textlen, &builder)
		}
		if .RETURN in ctx.key_pressed_bits {
			mu.set_focus(ctx, 0)
			res += {.SUBMIT}
		}

		// Pressing or dragging puts the caret where the pointer is.
		if .LEFT in ctx.mouse_down_bits {
			text := string(textbuf[:textlen^])
			x := ctx.mouse_pos.x - r.x - ctx.textbox_offset
			idx := len(text)
			if spans, shaped := spans_of(ctx, font, text, plain); shaped {
				idx = bidi_offset_at(spans, 0, len(text), f32(x))
			} else {
				for i in 0 ..< len(text) {
					// Not inside a character.
					if text[i] >= 0x80 && text[i] < 0xc0 {
						continue
					}
					if x < ctx.text_width(font, text[:i]) {
						idx = i
						break
					}
				}
			}
			s.selection[0] = idx
			if .LEFT in ctx.mouse_pressed_bits && !shift {
				s.selection[1] = idx
			}
		}
	}

	text := string(textbuf[:textlen^])
	mu.draw_control_frame(ctx, id, r, .BASE, opt)
	if ctx.focus_id != id {
		mu.draw_control_text(ctx, text, r, .TEXT, opt)
		return
	}
	text_color := ctx.style.colors[.TEXT]
	textw := ctx.text_width(font, text)
	texth := ctx.text_height(font)
	spans, shaped := spans_of(ctx, font, text, plain)
	// The caret and the selection's stretches, from the text's start.
	headx: i32
	ranges := make([dynamic][2]i32, context.temp_allocator)
	lo, hi := min(s.selection[0], s.selection[1]), max(s.selection[0], s.selection[1])
	if shaped {
		headx = round_px(bidi_caret_x(spans, 0, len(text), s.selection[0]))
		for rg in bidi_ranges(spans, lo, hi) {
			append(&ranges, [2]i32{round_px(rg[0]), round_px(rg[1])})
		}
	} else {
		headx = ctx.text_width(font, text[:s.selection[0]])
		append(&ranges, [2]i32{ctx.text_width(font, text[:lo]), ctx.text_width(font, text[:hi])})
	}
	// Scrolled so that the caret is in view, as microui's.
	ofmin := max(ctx.style.padding - headx, r.w - textw - ctx.style.padding)
	ofmax := min(r.w - headx - ctx.style.padding, ctx.style.padding)
	ctx.textbox_offset = clamp(ctx.textbox_offset, ofmin, ofmax)
	textx := r.x + ctx.textbox_offset
	texty := r.y + (r.h - texth) / 2
	mu.push_clip_rect(ctx, r)
	for rg in ranges {
		mu.draw_rect(ctx, {textx + rg[0], texty, rg[1] - rg[0], texth}, ctx.style.colors[.SELECTION_BG])
	}
	mu.draw_text(ctx, font, text, {textx, texty}, text_color)
	mu.draw_rect(ctx, {textx + headx, texty, 1, texth}, text_color)
	mu.pop_clip_rect(ctx)
	return
}
