package client

import "base:intrinsics"
import "core:fmt"
import mu "vendor:microui"

// A dropdown, which microui doesn't have: a button showing the current choice
// that, clicked, opens the list of choices under it. The list is a popup of
// its own, drawn at the end of the frame over everything else
// (dropdown_popup, from layout), with a scrollbar when it is longer than the
// window. Picking from it is returned by the dropdown in the next frame.
// One list is open at a time.

Dropdown_Item :: struct {
	label:  string,
	header: bool, // a heading over the choices after it, not a choice
}

Dropdown_State :: struct {
	open:      mu.Id, // the dropdown whose list is open, 0 for none
	requested: bool, // the list opens in this frame
	// The open dropdown's button, choices and current choice, as of this
	// frame (`frame`). The items are the caller's, in the temp allocator.
	anchor:    mu.Rect,
	items:     []Dropdown_Item,
	current:   int,
	frame:     mu.Frame_Index,
	// What was picked from the list, for the dropdown `picked_id`.
	picked:    int,
	picked_id: mu.Id,
}

@(private = "file")
DROPDOWN_POPUP :: "dropdown list"

// The least width of an open list.
@(private = "file")
DROPDOWN_MIN_WIDTH :: 200

// How wide a dropdown of a setting's choices is (choice_dropdown), in a
// field_row.
CHOICE_WIDTH :: 220

// dropdown draws a dropdown that shows `label`, choosing from `items` with
// `current` marked, and `hint` while the pointer is on it. It returns the
// index of the item picked, if one was.
dropdown :: proc(
	ui: ^UI,
	id_name, label: string,
	items: []Dropdown_Item,
	current: int,
	hint := "",
) -> (
	picked: int,
	ok: bool,
) {
	ctx := &ui.ctx
	d := &ui.dropdown
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
		d.open, d.requested = id, true
	}
	mu.draw_control_frame(ctx, id, r, .BUTTON)
	text := r
	text.w -= r.h
	mu.draw_control_text(ctx, label, text, .TEXT, {})
	mu.draw_icon(ctx, .EXPANDED, {r.x + r.w - r.h, r.y, r.h, r.h}, ctx.style.colors[.TEXT])
	if hint != "" && ctx.hover_id == id {
		ui.hint, ui.hint_of = hint, r
	}
	if d.open == id {
		d.anchor, d.items, d.current, d.frame = r, items, current, ctx.frame
	}
	if d.picked_id == id {
		picked, ok = d.picked, true
		d.picked_id = 0
	}
	return
}

// choice_dropdown is a dropdown of a setting's choices, `labels`, showing the
// current one, or `none` while there is none (`current` -1). It returns the
// choice picked, if one was other than the current one.
choice_dropdown :: proc(
	ui: ^UI,
	id_name: string,
	labels: []string,
	current: int,
	hint := "",
	none := "",
) -> (
	picked: int,
	ok: bool,
) {
	items := make([]Dropdown_Item, len(labels), context.temp_allocator)
	for l, i in labels {
		items[i] = {
			label = l,
		}
	}
	label := labels[current] if current >= 0 && current < len(labels) else none
	picked, ok = dropdown(ui, id_name, label, items, current, hint)
	return picked, ok && picked != current
}

// enum_dropdown is choice_dropdown for a setting that is an enum, with a label
// for each of its values.
enum_dropdown :: proc(
	ui: ^UI,
	id_name: string,
	labels: [$E]string,
	current: E,
	hint := "",
) -> (
	picked: E,
	ok: bool,
) where intrinsics.type_is_enum(E) {
	names := make([dynamic]string, 0, len(E), context.temp_allocator)
	values := make([dynamic]E, 0, len(E), context.temp_allocator)
	at := -1
	for label, value in labels {
		if value == current {
			at = len(names)
		}
		append(&names, label)
		append(&values, value)
	}
	i := choice_dropdown(ui, id_name, names[:], at, hint) or_return
	return values[i], true
}

// dropdown_popup draws the open dropdown's list. The list is closed by
// picking from it, by clicking elsewhere, and when its dropdown is no longer
// drawn (another page is shown).
dropdown_popup :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	d := &ui.dropdown
	if d.open == 0 {
		return
	}
	if d.frame != ctx.frame {
		if cnt := mu.get_container(ctx, DROPDOWN_POPUP, {.CLOSED}); cnt != nil {
			cnt.open = false
		}
		d.open = 0
		return
	}
	if d.requested {
		d.requested = false
		mu.open_popup(ctx, DROPDOWN_POPUP)
		cnt := mu.get_container(ctx, DROPDOWN_POPUP)
		// As microui lays a row out: its size and padding, then the spacing,
		// which the last row doesn't need. The window's padding is around them.
		row := ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing
		want := i32(len(d.items)) * row - ctx.style.spacing + 2 * ctx.style.padding
		width := max(d.anchor.w, DROPDOWN_MIN_WIDTH)
		below := h - (d.anchor.y + d.anchor.h)
		above := d.anchor.y
		rect := mu.Rect{d.anchor.x, d.anchor.y + d.anchor.h, width, min(want, below)}
		if want > below && above > below {
			// More room above: open upwards.
			rect.h = min(want, above)
			rect.y = d.anchor.y - rect.h
		}
		rect.x = clamp(rect.x, 0, max(w - rect.w, 0))
		cnt.rect = rect
		cnt.scroll = {}
		// Scrolled to the current choice, if the list is longer than its room.
		if d.current >= 0 && want > rect.h {
			cnt.scroll.y = max(i32(d.current) * row - rect.h / 2, 0)
		}
	}
	if !mu.begin_window(ctx, DROPDOWN_POPUP, {}, {.POPUP, .NO_RESIZE, .NO_TITLE, .CLOSED}) {
		d.open = 0
		return
	}
	defer mu.end_window(ctx)
	mu.layout_row(ctx, {-1})
	for item, i in d.items {
		if item.header {
			with_text_color(ctx, theme.dim, item.label, label_proc)
			continue
		}
		if .SUBMIT in
		   list_row(ctx, fmt.tprintf("dropdown item %d", i), item.label, i == d.current) {
			d.picked, d.picked_id = i, d.open
			d.open = 0
			mu.get_current_container(ctx).open = false
			ui_redraw(ui)
		}
	}
}
