#+build wasi
package client

import "core:hash"
import mu "vendor:microui"

import "client:platform"
import "client:render"

// In a web build a text area (ui_text_area.odin) is the page's own <textarea>
// (web/field.js), laid over the box that the canvas draws. The browser draws
// and edits the text, so spell checking, a phone's own caret handling (the
// magnifier, the selection handles, the space bar as a trackpad), autocorrect,
// dictation and input methods all work as on any page.
//
// The text area's buffer stays what the client works with, and the two are
// kept the same both ways:
//
// - What is done in the field comes as its whole text and selection
//   (web_field_input), and is kept until the text area is next laid out, or
//   its composer next looks at its keys (composer_input), and copied into the
//   buffer then (field_take).
// - What the client changes itself (completing a word, the markdown keys,
//   sending, starting to edit a message) is found different from what the two
//   last agreed on when the text area is next laid out, and given to the field
//   (field_place).
//
// Of the keys typed in the field, the ones the composers act on (Enter to send,
// Tab, Escape, Up and Down, the markdown keys) go on to GLFW as before; the
// rest are the field's alone (web/field.js).
//
// After each frame, the fields are put where their text areas were laid out,
// with their font, colors and insets. Where one of microui's windows (a menu, a
// dialog) is over a text area, the field is hidden, and the text area is drawn
// and edited on the canvas as in a desktop build until it is uncovered again.

// What was done in a field, waiting for its text area: the whole text (UTF-8)
// and the selection (caret, then anchor, in bytes).
@(private = "file")
Field_Input :: struct {
	text: [dynamic]u8,
	sel:  [2]int,
}

// Where a text area was laid out in this frame, and how its text looks there.
@(private = "file")
Field_Place :: struct {
	id:                         mu.Id,
	rect:                       mu.Rect, // the box's part with the text
	clip:                       mu.Rect, // what of the box can be seen
	root:                       ^mu.Container, // the window it is in
	focused:                    bool,
	pad_x, pad_top, pad_bottom: i32, // from the text rect's edges to the text
	font:                       mu.Font,
	line:                       i32,
	color, selection:           mu.Color,
}

@(private = "file")
g_input: map[mu.Id]Field_Input
// The field that the page gave the focus to (a click or tap on it).
@(private = "file")
g_focus: mu.Id
// How many lines each field wraps its text into, as the page measured it.
@(private = "file")
g_lines: map[mu.Id]int
// The fields that were covered by a window in the last frame.
@(private = "file")
g_covered: map[mu.Id]bool
@(private = "file")
g_placed: [dynamic]Field_Place
@(private = "file")
g_font_given: bool

@(private = "file")
Field_Flag :: enum i32 {
	Focused,
	Covered,
	Enter_Sends, // Enter sends; on a phone's keyboard it starts a line
	Completing, // the completion list is open for it (ui_completion.odin)
}

@(default_calling_convention = "c")
foreign _ {
	// Gives the page the font file the fields' text is in.
	yap_field_font :: proc(data: [^]u8, n: i32) ---
	// Puts text and a selection (caret, anchor: bytes into it) in a field,
	// making the field if there is none.
	yap_field_text :: proc(id: u32, text: [^]u8, n: i32, caret, anchor: i32) ---
	yap_field_select :: proc(id: u32, caret, anchor: i32) ---
	// The fields placed between these two are shown, the others hidden. Sizes
	// are in CSS pixels, from the canvas' corner.
	yap_fields_begin :: proc() ---
	yap_field_place :: proc(id: u32, x, y, w, h, cx, cy, cw, ch, pad_x, pad_top, pad_bottom, em, line: f64, color, selection: u32, flags: i32) ---
	yap_fields_end :: proc() ---
}

// field_take copies what was done in the field for the text area `id` into its
// buffer and selection, gives it the focus if the page did, and notes in `area`
// whether the field stands in for it in this frame. Call before the text area
// is laid out.
field_take :: proc(ui: ^UI, id: mu.Id, buf: []u8, textlen: ^int, area: ^Text_Area) {
	ctx := &ui.ctx
	area.field.live = !g_covered[id]
	area.field.lines = g_lines[id]
	if g_focus == id {
		g_focus = 0
		mu.set_focus(ctx, id)
		ctx.textbox_state.id = u64(id)
	}
	input, ok := g_input[id]
	if !ok {
		return
	}
	delete_key(&g_input, id)
	defer delete(input.text)

	// What doesn't fit is cut off, at the start of a character. The field
	// then differs from the buffer, and gets it back (field_place).
	n := min(len(input.text), len(buf))
	for n > 0 && n < len(input.text) && input.text[n] & 0xc0 == 0x80 {
		n -= 1
	}
	if string(buf[:textlen^]) != string(input.text[:n]) {
		copy(buf, input.text[:n])
		textlen^ = n
		area.field.changed = true
	}
	area.field.synced = true
	area.field.hash = hash.fnv64a(input.text[:])
	area.field.len = len(input.text)
	area.field.sel = input.sel
	if ctx.focus_id == id {
		ctx.textbox_state.id = u64(id)
		ctx.textbox_state.selection = {
			clamp(input.sel[0], 0, textlen^),
			clamp(input.sel[1], 0, textlen^),
		}
	}
}

// field_place gives the field for the text area `id` what the client changed
// in its text or selection, and notes where the text area's text was laid out:
// in `tr`, with `top` above its first line and `bottom` below its last. Call
// while the text area is laid out.
field_place :: proc(
	ui: ^UI,
	id: mu.Id,
	text: string,
	area: ^Text_Area,
	tr: mu.Rect,
	top, bottom: i32,
	focused: bool,
) {
	ctx := &ui.ctx
	sel := [2]int{len(text), len(text)}
	if focused {
		s := ctx.textbox_state.selection
		sel = {clamp(s[0], 0, len(text)), clamp(s[1], 0, len(text))}
	}
	h := hash.fnv64a(transmute([]u8)text)
	if !area.field.synced || h != area.field.hash || len(text) != area.field.len {
		yap_field_text(u32(id), raw_data(text), i32(len(text)), i32(sel[0]), i32(sel[1]))
		area.field.synced, area.field.hash, area.field.len = true, h, len(text)
		area.field.sel = sel
	} else if focused && sel != area.field.sel {
		yap_field_select(u32(id), i32(sel[0]), i32(sel[1]))
		area.field.sel = sel
	}

	font := ctx.style.font
	line := ctx.text_height(font)
	append(
		&g_placed,
		Field_Place {
			id = id,
			rect = tr,
			clip = mu.intersect_rects(tr, mu.get_clip_rect(ctx)),
			root = ctx.container_stack.items[0],
			focused = focused,
			pad_x = ctx.style.padding,
			pad_top = top,
			pad_bottom = bottom,
			font = font,
			line = line,
			color = ctx.style.colors[.TEXT],
			selection = ctx.style.colors[.SELECTION_BG],
		},
	)
}

// fields_after_frame shows the fields where their text areas were laid out
// in this frame, and hides the others. Call after mu.end.
fields_after_frame :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !g_font_given && len(g_placed) > 0 {
		data := render.face_data(.Regular)
		yap_field_font(raw_data(data), i32(len(data)))
		g_font_given = true
	}
	rgba :: proc(c: mu.Color) -> u32 {
		return u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | u32(c.a)
	}
	// Layout pixels to CSS pixels.
	k := 1 / f64(ui.input_scale)
	yap_fields_begin()
	roots := ctx.root_list.items[:ctx.root_list.idx]
	for p in g_placed {
		covered := false
		for cnt in roots {
			if cnt != p.root && cnt.open && cnt.zindex > p.root.zindex {
				over := mu.intersect_rects(cnt.rect, p.clip)
				if over.w > 0 && over.h > 0 {
					covered = true
					break
				}
			}
		}
		if covered != g_covered[p.id] {
			g_covered[p.id] = covered
			ui_redraw(ui) // drawn on the canvas, or no longer
		}
		flags: bit_set[Field_Flag;i32]
		if p.focused {
			flags += {.Focused}
		}
		if covered {
			flags += {.Covered}
		}
		if !ui.touched {
			flags += {.Enter_Sends}
		}
		if ui.completion.active && ui.completion.box == p.id {
			flags += {.Completing}
		}
		yap_field_place(
			u32(p.id),
			f64(p.rect.x) * k,
			f64(p.rect.y) * k,
			f64(p.rect.w) * k,
			f64(p.rect.h) * k,
			f64(p.clip.x) * k,
			f64(p.clip.y) * k,
			f64(p.clip.w) * k,
			f64(p.clip.h) * k,
			f64(p.pad_x) * k,
			f64(p.pad_top) * k,
			f64(p.pad_bottom) * k,
			f64(render.ui_font_em(p.font)) * k,
			f64(p.line) * k,
			rgba(p.color),
			rgba(p.selection),
			transmute(i32)flags,
		)
	}
	yap_fields_end()

	// What was done in a field whose text area is gone is dropped.
	gone := make([dynamic]mu.Id, context.temp_allocator)
	for id in g_input {
		if !field_placed(id) {
			append(&gone, id)
		}
	}
	for id in gone {
		delete(g_input[id].text)
		delete_key(&g_input, id)
	}
	if g_focus != 0 && !field_placed(g_focus) {
		g_focus = 0
	}
	clear(&g_placed)
}

@(private = "file")
field_placed :: proc(id: mu.Id) -> bool {
	for p in g_placed {
		if p.id == id {
			return true
		}
	}
	return false
}

// What was done in a field: its whole text (`n` bytes of UTF-8) and its
// selection (caret, anchor: bytes into the text).
@(export)
web_field_input :: proc "c" (id: u32, text: [^]u8, n: i32, caret, anchor: i32) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	input := g_input[mu.Id(id)]
	clear(&input.text)
	append(&input.text, ..text[:n])
	input.sel = {int(caret), int(anchor)}
	g_input[mu.Id(id)] = input
	ui_redraw(g_ui)
	ui_wake()
}

// The page gave a field the focus.
@(export)
web_field_focus :: proc "c" (id: u32) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	g_focus = mu.Id(id)
	ui_redraw(g_ui)
	ui_wake()
}

// How many lines a field's text takes, at its width.
@(export)
web_field_lines :: proc "c" (id: u32, lines: i32) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	g_lines[mu.Id(id)] = int(lines)
	ui_redraw(g_ui)
	ui_wake()
}

// A finger touched a field: from now on the UI is for fingers (UI.touched), as
// after a touch anywhere else.
@(export)
web_field_touched :: proc "c" () {
	context = platform.callback_context()
	if g_ui == nil || g_ui.touched {
		return
	}
	g_ui.touched = true
	ui_redraw(g_ui)
	ui_wake()
}
