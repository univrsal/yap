package client

import "base:intrinsics"
import "client:conn"
import "client:render"
import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"

// Widgets used all over the UI, on top of microui's.

// A button with nothing but an icon on it is this wide, or as wide as it is
// tall where rows are taller (icon_button_w).
ICON_BUTTON :: 30

// icon_button_w is how wide a button with only an icon on it is: square on a
// phone, where rows are a fingertip tall (style_apply).
icon_button_w :: proc(ctx: ^mu.Context) -> i32 {
	return max(ICON_BUTTON, ctx.style.size.y + 2 * ctx.style.padding)
}

// draw_frame_themed is microui's draw_frame (render.draw_frame), except that a
// focused text box has a ring in the theme's accent color (its border and one
// more line inside it), and a window that floats over the main window casts a
// shadow.
draw_frame_themed :: proc(ctx: ^mu.Context, rect: mu.Rect, colorid: mu.Color_Type) {
	// A window's frame is drawn while it is the current container
	// (begin_window). The main window and the rail are below everything.
	if colorid == .WINDOW_BG &&
	   ctx.container_stack.idx > 0 &&
	   mu.get_current_container(ctx).zindex >= 0 {
		render.draw_shadow(ctx, rect, theme.shadow)
	}
	if colorid == .SCROLL_BASE || colorid == .SCROLL_THUMB {
		scrollbar_frame(g_ui, rect, colorid)
		return
	}
	if colorid != .BASE_FOCUS {
		render.draw_frame(ctx, rect, colorid)
		return
	}
	// The outer line is snapped from the inner one, so that the two touch
	// on every side at any scale.
	radius := i32(render.CONTROL_RADIUS - 1)
	render.draw_rounded_outside(ctx, rect, ctx.style.colors[colorid], radius)
	render.draw_rounded_outside(ctx, rect, theme.accent, radius, border = true)
	render.draw_rounded_border(ctx, rect, theme.accent, radius)
}

// icon_button is a button with an icon on it instead of a label. While the
// pointer is on it, a hint below it shows the words the icon saves. Like
// stable_button, its id comes from `id_name`, so a button that changes
// what it shows (mute to unmute) keeps the same id.
icon_button :: proc(
	ui: ^UI,
	id_name: string,
	icon: render.Icon,
	hint: string,
	color := mu.Color{},
) -> (
	res: mu.Result_Set,
) {
	ctx := &ui.ctx
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	keyed := nav_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id || keyed {
		res += {.SUBMIT}
	}
	// Filled, without a border, or flat: a background only while the pointer
	// is on it or it is pressed.
	colorid := mu.Color_Type.BUTTON
	if ctx.focus_id == id {
		colorid = .BUTTON_FOCUS
	} else if ctx.hover_id == id {
		colorid = .BUTTON_HOVER
	}
	if !ui.flat_buttons || colorid != .BUTTON {
		render.draw_rounded(ctx, r, ctx.style.colors[colorid], render.CONTROL_RADIUS)
	}
	mu.draw_icon(ctx, render.icon_id(icon), r, color if color.a != 0 else ctx.style.colors[.TEXT])
	if ctx.hover_id == id || nav_focused(ctx, id) {
		ui.hint, ui.hint_of = hint, r
	}
	return
}

// A spinner turns once a second, a step at a time.
SPINNER_STEP :: time.Second / render.SPINNER_STEPS

// spinner says that something is loading: a turning ring in the middle of
// `r`, dim unless it gets a `color`. While it is on screen, it asks for a frame
// when it is to turn next, and only then: a spinner scrolled out of view
// costs no frames.
spinner :: proc(ui: ^UI, r: mu.Rect, color := mu.Color{}) {
	ctx := &ui.ctx
	if mu.check_clip(ctx, r) == .ALL {
		return
	}
	// The same step everywhere, from the clock.
	ns := time.tick_now()._nsec
	step := ns / i64(SPINNER_STEP)
	mu.draw_icon(
		ctx,
		render.spinner_id(int(step % render.SPINNER_STEPS)),
		r,
		color if color.a != 0 else theme.dim,
	)
	ui_redraw_in(ui, time.Duration(i64(SPINNER_STEP) - ns % i64(SPINNER_STEP)))
}

// spinner_row is a row of its own with a spinner in its middle.
spinner_row :: proc(ui: ^UI) {
	mu.layout_row(&ui.ctx, {-1})
	spinner(ui, mu.layout_next(&ui.ctx))
}

// menu_list_begin starts a list of `rows` rows in a menu, `width` wide. The rows
// are buttons or labels, each on a row of its own, laid out with {-1}. The list
// is as tall as its rows, up to half the window, beyond which it scrolls instead
// of the menu growing off the window. It has no frame or padding of its own, so
// its rows line up with the menu's. End it with mu.end_panel.
menu_list_begin :: proc(ui: ^UI, name: string, width: i32, rows: int) {
	ctx := &ui.ctx
	row := ctx.style.size.y + 2 * ctx.style.padding
	tall := i32(rows) * (row + ctx.style.spacing) - ctx.style.spacing
	most := max(i32(ui.metrics.logical_h) / 2, 3 * row)
	mu.layout_row(ctx, {width}, clamp(tall, 0, most))
	padding := ctx.style.padding
	ctx.style.padding = 0
	mu.begin_panel(ctx, name, {.NO_FRAME})
	ctx.style.padding = padding
}

// icon_hint draws what the icon button under the pointer does, just below
// it, or the tooltip of whatever else set `ui.hint`, which may run over
// several lines. microui paints each window and popup as a whole, in
// z-order, so the hint gets a frameless window of its own, raised above
// the rest. If it were drawn inside the main window, a popup (the user menu)
// would cover it.
@(private = "file")
HINT_WINDOW :: "hint"

// The emoji a hint is about: one of the server's (by its index), or else a
// character as a string. Both are empty for none.
Hint_Emoji :: struct {
	custom:  Maybe(int),
	unicode: string, // temp
}

// hint_emoji_of makes the hint show `emoji` large: a reaction's or
// message's emoji, ":name:" for the server's, else the characters. Call with
// the View locked.
hint_emoji_of :: proc(ui: ^UI, emoji: string) {
	if strings.has_prefix(emoji, ":") && strings.has_suffix(emoji, ":") && len(emoji) > 2 {
		name := emoji[1:len(emoji) - 1]
		for n, i in ui.view.emoji.names {
			if n == name {
				ui.hint_emoji = {
					custom = i,
				}
				return
			}
		}
		return
	}
	ui.hint_emoji = {
		unicode = emoji,
	}
}

icon_hint :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	if ui.hint == "" {
		return
	}
	emoji := ui.hint_emoji
	defer ui.hint, ui.hint_emoji = "", {}

	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	w, lines: i32
	rest := ui.hint
	for line in strings.split_lines_iterator(&rest) {
		w = max(w, ctx.text_width(ctx.style.font, line))
		lines += 1
	}
	// The emoji, large, above the text.
	big_w, big_h: i32
	if _, custom := emoji.custom.?; custom || emoji.unicode != "" {
		big_h = ctx.text_height(render.PREVIEW_FONT)
		big_w = big_h
		if !custom {
			big_w = ctx.text_width(render.PREVIEW_FONT, emoji.unicode)
		}
		w = max(w, big_w)
	}
	w += 2 * pad
	h := lines * line_h + 2 * pad
	if big_h > 0 {
		h += big_h + pad
	}
	// Under the button, moved left if it would go off the side, and
	// above it if there is no room below (the chat box's Send button).
	x := min(ui.hint_of.x, max(window_w - w, 0))
	y := ui.hint_of.y + ui.hint_of.h + 2
	if y + h > window_h {
		y = max(ui.hint_of.y - h - 2, 0)
	}
	r := mu.Rect{x, y, w, h}
	// The pointer is on the button, never on the hint, so the window
	// doesn't take the hover away from the thing it describes.
	cnt := mu.get_container(ctx, HINT_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(
		ctx,
		HINT_WINDOW,
		r,
		{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT},
	) {
		return
	}
	defer mu.end_window(ctx)
	render.draw_rounded(ctx, r, ctx.style.colors[.BASE], render.CONTROL_RADIUS)
	render.draw_rounded_border(ctx, r, ctx.style.colors[.BORDER], render.CONTROL_RADIUS)
	line_y := y + pad
	if big_h > 0 {
		at := mu.Vec2{x + (w - big_w) / 2, line_y}
		if index, custom := emoji.custom.?; custom {
			if icon, ok := custom_emoji_icon(ui, index); ok {
				mu.draw_icon(ctx, icon, {at.x, at.y, big_w, big_h}, {255, 255, 255, 255})
			}
		} else {
			mu.draw_text(ctx, render.PREVIEW_FONT, emoji.unicode, at, ctx.style.colors[.TEXT])
		}
		line_y += big_h + pad
	}
	rest = ui.hint
	for line in strings.split_lines_iterator(&rest) {
		mu.draw_text(ctx, ctx.style.font, line, {x + pad, line_y}, ctx.style.colors[.TEXT])
		line_y += line_h
	}
}

// stable_button_hint is stable_button with a hint below it while the pointer is
// on it, like icon_button's.
stable_button_hint :: proc(
	ui: ^UI,
	id_name: string,
	label: string,
	hint: string,
	opt: mu.Options = {},
) -> mu.Result_Set {
	res := stable_button(&ui.ctx, id_name, label, opt)
	if ui.ctx.hover_id == mu.get_id(&ui.ctx, id_name) {
		ui.hint, ui.hint_of = hint, ui.ctx.last_rect
	}
	return res
}

// stable_button is mu.button, except that its id comes from `id_name` (under
// the current id stack) instead of from the label, so the label can
// change from frame to frame without the button becoming a new control.
stable_button :: proc(
	ctx: ^mu.Context,
	id_name: string,
	label: string,
	opt: mu.Options = {},
) -> (
	res: mu.Result_Set,
) {
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	keyed := nav_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id || keyed {
		res += {.SUBMIT}
	}
	mu.draw_control_frame(ctx, id, r, .BUTTON)
	mu.draw_control_text(ctx, label, r, .TEXT, opt)

	return
}

// button is mu.button with a label, as a stable_button: Tab stops at it.
button :: proc(ctx: ^mu.Context, label: string, opt: mu.Options = {.ALIGN_CENTER}) -> mu.Result_Set {
	return stable_button(ctx, label, label, opt)
}

// header is mu.header, and begin_treenode mu.begin_treenode (closed with
// mu.end_treenode), which Tab also stops at: Enter or Space opens or closes
// them.
header :: proc(ctx: ^mu.Context, label: string, opt: mu.Options = {}) -> mu.Result_Set {
	keyed_toggle(ctx, label)
	res := mu.header(ctx, label, opt)
	nav_control(ctx, mu.get_id(ctx, label), ctx.last_rect)
	return res
}

begin_treenode :: proc(ctx: ^mu.Context, label: string, opt: mu.Options = {}) -> mu.Result_Set {
	keyed_toggle(ctx, label)
	id := mu.get_id(ctx, label)
	res := mu.begin_treenode(ctx, label, opt)
	// An open tree node has pushed its id already: register it as it was.
	nav_control(ctx, id, ctx.last_rect)
	return res
}

// keyed_toggle opens or closes the header `label` if Enter or Space pressed
// it, as a click would, before microui looks at whether it is open.
@(private = "file")
keyed_toggle :: proc(ctx: ^mu.Context, label: string) {
	id := mu.get_id(ctx, label)
	if !nav_activated(ctx, id) {
		return
	}
	if i, open := mu.pool_get(ctx, ctx.treenode_pool[:], id); open {
		ctx.treenode_pool[i] = {}
	} else {
		mu.pool_init(ctx, ctx.treenode_pool[:], id)
	}
}

// list_row is a line of a list to pick from (such as a settings tab's
// categories or the channels), shown as text. It is boxed and bold while it is
// the selected one and highlighted under the mouse. Clicking it with the left
// button submits it. With `accent`, the selected one is in the accent color
// (what is shown: a settings category, the channel that is open), rather than
// grey (the current choice in a dropdown or a list of options).
list_row :: proc(
	ctx: ^mu.Context,
	id_name, label: string,
	selected: bool,
	accent := false,
) -> (
	res: mu.Result_Set,
) {
	id := mu.get_id(ctx, id_name)
	r := mu.layout_next(ctx)
	mu.update_control(ctx, id, r)
	keyed := nav_control(ctx, id, r, list = true, current = selected)
	if ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} || keyed {
		res += {.SUBMIT}
	}
	switch {
	case selected && accent:
		color := theme.accent_hover if ctx.hover_id == id else theme.accent
		render.draw_rounded(ctx, r, color, render.CONTROL_RADIUS)
	case selected:
		render.draw_rounded(ctx, r, ctx.style.colors[.BUTTON_FOCUS], render.CONTROL_RADIUS)
	case ctx.hover_id == id:
		render.draw_rounded(ctx, r, ctx.style.colors[.BUTTON_HOVER], render.CONTROL_RADIUS)
	}
	saved, saved_text := ctx.style.font, ctx.style.colors[.TEXT]
	if selected {
		ctx.style.font = render.font_with_style(saved, .Bold)
	}
	if selected && accent {
		ctx.style.colors[.TEXT] = theme.accent_text
	}
	mu.draw_control_text(ctx, label, r, .TEXT, {})
	ctx.style.font, ctx.style.colors[.TEXT] = saved, saved_text
	return
}

// checkbox is mu.checkbox, except that it is ticked when the mouse button
// goes down on it, like a button, instead of when it comes up. Otherwise a
// press that closes a dropdown's list (dropdown_popup) or changes the
// settings page under the pointer would tick the checkbox that is there
// when the button comes up.
checkbox :: proc(ctx: ^mu.Context, label: string, state: ^bool) -> (res: mu.Result_Set) {
	id := mu.get_id(ctx, uintptr(state))
	r := mu.layout_next(ctx)
	box := mu.Rect{r.x, r.y, r.h, r.h}
	mu.update_control(ctx, id, r)
	keyed := nav_control(ctx, id, r)
	if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id || keyed {
		res += {.CHANGE}
		state^ = !state^
	}
	mu.draw_control_frame(ctx, id, box, .BASE)
	if state^ {
		mu.draw_icon(ctx, .CHECK, box, ctx.style.colors[.TEXT])
	}
	mu.draw_control_text(ctx, label, {r.x + box.w, r.y, r.w - box.w, r.h}, .TEXT)
	return
}

label_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.label(ctx, text)
}

with_text_color :: proc(
	ctx: ^mu.Context,
	color: mu.Color,
	text: string,
	widget: proc(ctx: ^mu.Context, text: string),
) {
	saved := ctx.style.colors[.TEXT]
	ctx.style.colors[.TEXT] = color
	widget(ctx, text)
	ctx.style.colors[.TEXT] = saved
}

// dim_label shows a line in the dim colour of notes and hints, dim_note the
// same wrapped to the row's width (wrap_text); error_label and error_note
// show an error.
dim_label :: proc(ctx: ^mu.Context, text: string) {
	with_text_color(ctx, theme.dim, text, label_proc)
}

dim_note :: proc(ctx: ^mu.Context, text: string) {
	with_text_color(ctx, theme.dim, text, wrap_text)
}

error_label :: proc(ctx: ^mu.Context, text: string) {
	with_text_color(ctx, theme.error, text, label_proc)
}

error_note :: proc(ctx: ^mu.Context, text: string) {
	with_text_color(ctx, theme.error, text, wrap_text)
}

// In a narrow window (a phone), a row of settings that wouldn't fit across
// goes down instead: field_row puts its label on a line of its own, above the
// controls, and fit_widths shrinks fixed widths that still don't fit. In a
// wide window everything is laid out as requested.

// How wide a fill (a width of 0 or less) counts when working out whether a
// row fits.
FILL_MIN :: 100

// row_room is the width that a row laid out now gets.
row_room :: proc(ctx: ^mu.Context) -> i32 {
	layout := mu.get_layout(ctx)
	return layout.body.w - layout.indent
}

// row_fits says whether `widths` fit across a row laid out now, with a fill
// counted as `fill_min` wide.
row_fits :: proc(ctx: ^mu.Context, widths: []i32, fill_min: i32 = FILL_MIN) -> bool {
	need := i32(max(len(widths) - 1, 0)) * ctx.style.spacing
	for w in widths {
		need += w if w > 0 else fill_min
	}
	return need <= row_room(ctx)
}

// fit_widths is `widths` with the fixed ones shrunk in proportion if they
// don't fit across a row laid out now.
fit_widths :: proc(ctx: ^mu.Context, widths: []i32) -> []i32 {
	if row_fits(ctx, widths) {
		return widths
	}
	fixed, fills: i32
	for w in widths {
		if w > 0 {
			fixed += w
		} else {
			fills += 1
		}
	}
	room := row_room(ctx) - i32(len(widths) - 1) * ctx.style.spacing - fills * FILL_MIN
	out := make([]i32, len(widths), context.temp_allocator)
	copy(out, widths)
	if fixed > 0 && room > 0 {
		for &w in out {
			if w > 0 {
				w = max(w * room / fixed, 1)
			}
		}
	}
	return out
}

// field_row lays out a row with a label `label_w` wide followed by controls of
// `widths`, and draws the label. The controls are drawn by the caller. When
// that doesn't fit (a fill counts as `fill_min` wide), the label gets a line
// of its own (none if it is empty) and the controls go under it.
field_row :: proc(
	ui: ^UI,
	label_w: i32,
	label: string,
	widths: []i32,
	height: i32 = 0,
	fill_min: i32 = FILL_MIN,
) {
	ctx := &ui.ctx
	row := make([]i32, len(widths) + 1, context.temp_allocator)
	row[0] = label_w
	copy(row[1:], widths)
	if row_fits(ctx, row, fill_min) {
		mu.layout_row(ctx, row, height)
		mu.label(ctx, label)
		return
	}
	if label != "" {
		mu.layout_row(ctx, {-1})
		mu.label(ctx, label)
	}
	mu.layout_row(ctx, fit_widths(ctx, widths), height)
}

// wrap_text is mu.text as the settings' notes need it: the last word of the
// text wraps too (mu.text only measures a word that is followed by a space),
// and so does a word that is longer than a line, such as a path, like the
// chat's text does (wrap_line). It uses the text colour, for with_text_color.
wrap_text :: proc(ctx: ^mu.Context, text: string) {
	font := ctx.style.font
	mu.layout_begin_column(ctx)
	defer mu.layout_end_column(ctx)
	mu.layout_row(ctx, {-1}, ctx.text_height(font))
	rest := text
	for len(rest) > 0 {
		r := mu.layout_next(ctx)
		end, next := wrap_line(ctx, font, rest, r.w)
		mu.draw_text(ctx, font, rest[:end], {r.x, r.y}, ctx.style.colors[.TEXT])
		rest = rest[next:]
	}
}

// choice_button draws a button that is one of a set of choices, marked if it is
// the chosen one. It returns whether it was clicked.
choice_button :: proc(ui: ^UI, id, label: string, chosen: bool) -> bool {
	text := fmt.tprintf("> %s", label) if chosen else label
	return .SUBMIT in stable_button(&ui.ctx, id, text, {.ALIGN_CENTER})
}

// section_label is the heading of one of the list's sections.
section_label :: proc(ui: ^UI, text: string) {
	mu.layout_row(&ui.ctx, {-1})
	with_text_color(&ui.ctx, theme.dim, text, label_proc)
}

text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}

// card_begin starts a card in the middle of what is left of the main
// window, as the login screen has. It is LOGIN_CARD_WIDTH wide (or as wide as
// the space allows) and as tall as `h`, which holds its height in the last
// frame (as tall as possible the first time). It scrolls if it doesn't fit.
// card_end ends it and stores its height in `h`.
card_begin :: proc(ui: ^UI, name: string, h: i32) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, -1)
	area := mu.layout_next(ctx)
	w := min(area.w, LOGIN_CARD_WIDTH)
	ch := area.h if h <= 0 else min(h, area.h)
	mu.layout_set_next(ctx, {area.x + (area.w - w) / 2, area.y + (area.h - ch) / 2, w, ch}, false)
	mu.begin_panel(ctx, name)
}

card_end :: proc(ui: ^UI, h: ^i32) {
	ctx := &ui.ctx
	cnt := mu.get_current_container(ctx)
	mu.end_panel(ctx)
	h^ = cnt.content_size.y + 2 * ctx.style.padding
}

// card_heading is a row with `text` in the middle of a card.
card_heading :: proc(ui: ^UI, text: string) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	mu.draw_control_text(ctx, text, mu.layout_next(ctx), .TEXT, {.ALIGN_CENTER})
}

// tab_button is a stable_button that is drawn pressed while its tab is shown.
tab_button :: proc(ctx: ^mu.Context, id_name, label: string, active: bool) -> mu.Result_Set {
	if !active {
		return stable_button(ctx, id_name, label)
	}
	// In the accent color, with its label bold, so that the shown tab can be
	// recognized at a glance.
	saved := ctx.style.colors
	saved_font := ctx.style.font
	ctx.style.colors[.BUTTON] = theme.accent
	ctx.style.colors[.BUTTON_HOVER] = theme.accent_hover
	ctx.style.colors[.BUTTON_FOCUS] = theme.accent_hover
	ctx.style.colors[.TEXT] = theme.accent_text
	ctx.style.font = render.font_with_style(saved_font, .Bold)
	defer ctx.style.colors = saved
	defer ctx.style.font = saved_font
	return stable_button(ctx, id_name, label)
}

// header_line draws a conversation's header in `r`, on one line: `name`, then
// `more` (a channel's topic) dimmed, and `status` (who is typing, or that a
// message is being edited) at the right end. `more` gives way to `status`
// where both don't fit, and `status` to the name.
header_line :: proc(
	ctx: ^mu.Context,
	r: mu.Rect,
	name: string,
	name_color: mu.Color,
	more: string,
	status: string,
	status_color: mu.Color,
) {
	GAP :: 12
	font := ctx.style.font
	y := r.y + (r.h - ctx.text_height(font)) / 2
	x := r.x + ctx.style.padding
	mu.push_clip_rect(ctx, r)
	defer mu.pop_clip_rect(ctx)
	if name != "" {
		mu.draw_text(ctx, font, name, {x, y}, name_color)
		x += ctx.text_width(font, name) + GAP
	}
	end := r.x + r.w - ctx.style.padding
	if status != "" {
		sx := max(end - ctx.text_width(font, status), x)
		mu.draw_text(ctx, font, status, {sx, y}, status_color)
		end = sx - GAP
	}
	if more != "" && end > x {
		mu.push_clip_rect(ctx, {x, r.y, end - x, r.h})
		mu.draw_text(ctx, font, more, {x, y}, theme.dim)
		mu.pop_clip_rect(ctx)
	}
}

// List_Detail is a settings category with a list on the left and what is
// picked in it on the right (list_detail).
List_Detail :: struct {
	name:       string, // the picked thing's panel; the list's is "<name> list"
	list_width: i32,
	detail_min: i32, // the least room beside the list before the two take turns
	picked:     bool, // something is picked (or being made)
	title:      string, // what is picked, over it when the two take turns
	back_hint:  string, // the hint of the way back: what the list is
	list:       proc(ui: ^UI),
	detail:     proc(ui: ^UI), // what is picked, or what to show without
	back:       proc(ui: ^UI), // going back to the list
}

// list_detail lays out a List_Detail. In a narrow window the list and what
// is picked take turns, as the settings' categories do: the list, or what is
// picked under its title with a way back to the list.
list_detail :: proc(ui: ^UI, ld: List_Detail) {
	ctx := &ui.ctx
	list_name := strings.concatenate({ld.name, " list"}, context.temp_allocator)
	if row_room(ctx) < ld.list_width + ld.detail_min {
		if !ld.picked {
			mu.layout_row(ctx, {-1}, -1)
			mu.begin_panel(ctx, list_name)
			ld.list(ui)
			mu.end_panel(ctx)
			return
		}
		mu.layout_row(ctx, {40, -1})
		if .SUBMIT in icon_button(ui, fmt.tprintf("to %s", list_name), .Back, ld.back_hint) {
			ld.back(ui)
		}
		mu.label(ctx, ld.title)
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, ld.name)
		ld.detail(ui)
		mu.end_panel(ctx)
		return
	}
	mu.layout_row(ctx, {ld.list_width, -1}, -1)
	mu.begin_panel(ctx, list_name)
	ld.list(ui)
	mu.end_panel(ctx)
	mu.begin_panel(ctx, ld.name)
	ld.detail(ui)
	mu.end_panel(ctx)
}

// Notice_Mark keeps a screen from showing a notice that the server sent before
// the screen was opened (conn.View_Notice.count), which isn't about anything
// requested there. notice_mark_reset marks the opening, and
// notice_mark_update, at the top of the screen with the View locked, takes
// the count then.
Notice_Mark :: struct {
	seen:  int,
	reset: bool,
}

notice_mark_reset :: proc(m: ^Notice_Mark) {
	m.reset = true
}

notice_mark_update :: proc(m: ^Notice_Mark, v: ^conn.View) {
	if m.reset {
		m.reset = false
		m.seen = v.notice.count
	}
}

// notice_fresh is the server's last notice if it came after the screen was
// opened. Call with the View locked.
notice_fresh :: proc(m: Notice_Mark, v: ^conn.View) -> (text: string, ok: bool, fresh: bool) {
	if v.notice.text == "" || v.notice.count <= m.seen {
		return
	}
	return v.notice.text, v.notice.ok, true
}

// notice_row shows the server's last notice in a row of its own, if it is
// fresh (notice_fresh): what it made of something requested on the screen,
// such as a refusal.
notice_row :: proc(ui: ^UI, m: Notice_Mark, v: ^conn.View) {
	text, ok, fresh := notice_fresh(m, v)
	if !fresh {
		return
	}
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.notice_ok if ok else theme.error, text, wrap_text)
}

// confirm_button is a button that has to be pressed twice, for what can't be
// undone: `ask` first, then `confirm` in its place. It returns true on the
// second press. `armed` says whether it was pressed once.
confirm_button :: proc(ctx: ^mu.Context, armed: ^bool, id, ask, confirm: string) -> bool {
	if !armed^ {
		if .SUBMIT in stable_button(ctx, fmt.tprintf("%s?", id), ask, {.ALIGN_CENTER}) {
			armed^ = true
		}
		return false
	}
	if .SUBMIT in stable_button(ctx, id, confirm, {.ALIGN_CENTER}) {
		armed^ = false
		return true
	}
	return false
}

// release_slider is mu.slider for a setting that is applied only once the
// slider is let go, and says when that happens: applying it while dragging
// would move the slider out from under the pointer (the UI scale) or redo
// slow work for every step (the chat text's glyphs).
release_slider :: proc(
	ctx: ^mu.Context,
	value: ^f32,
	low, high, step: f32,
	format: string,
) -> (
	released: bool,
) {
	was_dragging := slider_dragged(ctx, value)
	res := slider(ctx, value, low, high, step, format)
	// A step with the arrow keys is let go at once.
	return (was_dragging || .CHANGE in res) && !slider_dragged(ctx, value)
}

// slider is mu.slider, which Tab also stops at. While it has the keyboard
// focus, Left and Right move it by `step` (by a hundredth without one).
slider :: proc(
	ctx: ^mu.Context,
	value: ^f32,
	low, high: f32,
	step: f32 = 0,
	format := mu.SLIDER_FMT,
) -> (
	res: mu.Result_Set,
) {
	res = mu.slider(ctx, value, low, high, step, format)
	id := mu.get_id(ctx, uintptr(value))
	nav_control(ctx, id, ctx.last_rect)
	if !nav_focused(ctx, id) {
		return
	}
	by := step if step != 0 else (high - low) / 100
	v := value^
	if .LEFT in ctx.key_pressed_bits {
		v -= by
	}
	if .RIGHT in ctx.key_pressed_bits {
		v += by
	}
	v = clamp(v, low, high)
	if v != value^ {
		value^ = v
		res += {.CHANGE}
	}
	return
}

// slider_dragged says whether the slider of `value` is being dragged.
slider_dragged :: proc(ctx: ^mu.Context, value: ^f32) -> bool {
	return ctx.focus_id == mu.get_id(ctx, uintptr(value))
}

// Text_Field is what a text box holds: up to N bytes of text.
Text_Field :: struct($N: int) {
	buf: [N]u8,
	len: int,
}

// field_text is a Text_Field's text. It points into the field.
field_text :: proc(f: ^Text_Field($N)) -> string {
	return string(f.buf[:f.len])
}

// field_set sets a Text_Field's text, cut to what fits.
field_set :: proc(f: ^Text_Field($N), text: string) {
	f.len = copy(f.buf[:], text)
}
