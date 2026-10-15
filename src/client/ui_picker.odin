package client

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"

import "common:proto"

// The emoji picker is a floating window with every emoji, one category at a
// time (the server's own first, if it has any), and a box to find emoji by
// shortcode. It is opened either by the smiley beside a composer, where
// picking an emoji puts it in that composer, or by "React" in a message's
// menu, where picking an emoji reacts to that message (conn/reactions.odin).
// Hovering an emoji shows its shortcode. When opened from a message's bar, the
// picker is placed just below the bar (or above it if there is no room below),
// so the pointer doesn't have to move far.

UI_Picker :: struct {
	open:          bool,
	placed:        bool,
	// The message to react to, or (0) the composer to write in: the page's
	// or a thread window's (Composer.thread).
	react_to:      proto.Msg_Id,
	thread:        int,
	// What the picker was opened from, so it can be placed beside it.
	// Otherwise it goes at the window's bottom right.
	anchor:        Maybe(mu.Rect),
	// The category shown: -1 for the server's own emoji, otherwise an
	category:      int,
	search:        [proto.MAX_EMOJI_NAME]u8,
	search_n:      int,
	hovered:       string, // the name of the emoji under the pointer (temporary)
	hovered_emoji: Hint_Emoji, // the hovered emoji itself, shown large
	hovered_rect:  mu.Rect, // and its position
}

@(private = "file")
PICKER_WINDOW :: "Emoji"
@(private = "file")
PICKER_CELL :: 28
@(private = "file")
PICKER_COLUMNS :: 10

// emoji_button is the smiley beside a composer, which opens the picker for it.
// Call with the View locked.
emoji_button :: proc(ui: ^UI, c: Composer) {
	p := &ui.picker
	if .SUBMIT in icon_button(ui, "emoji", .Smiley, "Emoji") {
		was := p.open && p.react_to == 0 && p.thread == c.thread
		open_picker(ui, 0)
		p.open = !was
		p.thread = c.thread
	}
}

// open_picker opens the picker for the composer (0) or to react to a message,
// beside `anchor` if there is one.
open_picker :: proc(ui: ^UI, react_to: proto.Msg_Id, anchor: Maybe(mu.Rect) = nil) {
	p := &ui.picker
	p.open, p.placed, p.react_to, p.anchor = true, false, react_to, anchor
	if p.category < 0 && len(ui.view.emoji.names) == 0 {
		p.category = 0
	}
}

// picker_window draws the picker while it is open.
picker_window :: proc(ui: ^UI, window_w, window_h: i32) {
	p := &ui.picker
	if !p.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	if ui.session == nil || v.status != .Connected {
		p.open = false
		return
	}
	width := i32(
		PICKER_COLUMNS * (PICKER_CELL + ctx.style.spacing) +
		2 * ctx.style.padding +
		ctx.style.scrollbar_size +
		8,
	)
	height := min(window_h - 80, 380)
	if !p.placed {
		p.placed = true
		if cnt := mu.get_container(ctx, PICKER_WINDOW); cnt != nil {
			cnt.rect = {window_w - width - 12, window_h - height - 44, width + 3, height}
			if a, ok := p.anchor.?; ok {
				// Its right edge below the anchor's, kept inside the window.
				w := width + 3
				x := clamp(a.x + a.w - w, 0, max(window_w - w, 0))
				y := a.y + a.h + 2
				if y + height > window_h {
					y = max(a.y - height - 2, 0)
				}
				cnt.rect = {x, y, w, height}
			}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, PICKER_WINDOW, {}, {.NO_RESIZE}) {
		p.open = false
		return
	}
	defer mu.end_window(ctx)

	// Search by shortcode or browse a category.
	mu.layout_row(ctx, {-1})
	text_box(ui, p.search[:], &p.search_n)
	search := strings.to_lower(string(p.search[:p.search_n]), context.temp_allocator)
	if search == "" {
		tabs := make([dynamic]i32, context.temp_allocator)
		if len(v.emoji.names) > 0 {
			append(&tabs, PICKER_CELL)
		}
		for _ in proto.Emoji_Category {
			append(&tabs, PICKER_CELL)
		}
		mu.layout_row(ctx, tabs[:], PICKER_CELL)
		if len(v.emoji.names) > 0 {
			if picker_tab(ui, "custom", ":", p.category == -1) {
				p.category = -1
			}
		}
		for cat in proto.Emoji_Category {
			first := category_first(cat)
			label := utf8.runes_to_string({first}, context.temp_allocator)
			if picker_tab(ui, fmt.tprint(cat), label, p.category == int(cat)) {
				p.category = int(cat)
			}
		}
	}

	p.hovered, p.hovered_emoji = "", {}
	mu.layout_row(ctx, {-1}, -(ctx.style.size.y + 2 * ctx.style.padding + ctx.style.spacing + 2))
	mu.begin_panel(ctx, "emoji grid")
	cells := make([]i32, PICKER_COLUMNS, context.temp_allocator)
	for &c in cells {
		c = PICKER_CELL
	}
	n := 0
	// cell takes the next cell and returns whether any of it is in view. A
	// category has hundreds of emoji and a search can find thousands, of which
	// only a few dozen are visible. The rest only take up their room.
	cell :: proc(ctx: ^mu.Context, cells: []i32, n: ^int) -> bool {
		if n^ % PICKER_COLUMNS == 0 {
			mu.layout_row(ctx, cells, PICKER_CELL)
		}
		n^ += 1
		r := mu.layout_next(ctx)
		if mu.check_clip(ctx, r) == .ALL {
			return false
		}
		mu.layout_set_next(ctx, r, false)
		return true
	}
	// The server's own emoji, when they are shown or found.
	if search != "" || p.category == -1 {
		for name, i in v.emoji.names {
			if search != "" && !strings.contains(name, search) {
				continue
			}
			if !cell(ctx, cells, &n) {
				continue
			}
			code := strings.concatenate({":", name, ":"}, context.temp_allocator)
			if custom_emoji_cell(ui, i, code) {
				picked(ui, code)
			}
		}
	}
	for e in proto.EMOJI {
		switch {
		case search != "":
			if !strings.contains(e.names, search) {
				continue
			}
		case int(e.category) != p.category:
			continue
		}
		if !cell(ctx, cells, &n) {
			continue
		}
		char := utf8.runes_to_string({e.r}, context.temp_allocator)
		mu.push_id(ctx, uintptr(e.r))
		if .SUBMIT in stable_button(ctx, "emoji", char, {.ALIGN_CENTER}) {
			picked(ui, char)
		}
		if ctx.hover_id == ctx.last_id {
			p.hovered = fmt.tprintf(":%s:", proto.emoji_name(e))
			p.hovered_emoji = {
				unicode = char,
			}
			p.hovered_rect = ctx.last_rect
		}
		mu.pop_id(ctx)
	}
	if n == 0 {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "No emoji by that name.", label_proc)
	}
	mu.end_panel(ctx)
	mu.layout_row(ctx, {-1})
	hint := p.hovered
	if hint == "" {
		hint =
			"Pick one to react with." if p.react_to != 0 else "Pick one to put it in the message."
	}
	with_text_color(ctx, theme.dim, hint, label_proc)
	// And the emoji itself, shown large beside its cell.
	if p.hovered != "" {
		ui.hint, ui.hint_of, ui.hint_emoji = p.hovered, p.hovered_rect, p.hovered_emoji
	}
}

// picker_tab is a category's button, drawn pressed while the category is shown.
@(private = "file")
picker_tab :: proc(ui: ^UI, id, label: string, active: bool) -> bool {
	ctx := &ui.ctx
	saved := ctx.style.colors[.BUTTON]
	if active {
		ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
	}
	defer ctx.style.colors[.BUTTON] = saved
	return .SUBMIT in stable_button(ctx, id, label, {.ALIGN_CENTER})
}

// custom_emoji_cell is one of the server's emoji as a button: the picture once
// the sheet has loaded, its name until then.
@(private = "file")
custom_emoji_cell :: proc(ui: ^UI, index: int, code: string) -> bool {
	ctx := &ui.ctx
	mu.push_id(ctx, uintptr(index))
	defer mu.pop_id(ctx)
	icon, have := custom_emoji_icon(ui, index)
	res := stable_button(ctx, "custom", "" if have else code)
	if have {
		r := ctx.last_rect
		size: i32 = 20
		mu.draw_icon(
			ctx,
			icon,
			{r.x + (r.w - size) / 2, r.y + (r.h - size) / 2, size, size},
			{255, 255, 255, 255},
		)
	}
	if ctx.hover_id == ctx.last_id {
		ui.picker.hovered = code
		ui.picker.hovered_emoji = {
			custom = index,
		}
		ui.picker.hovered_rect = ctx.last_rect
	}
	return .SUBMIT in res
}

// category_first is the first emoji of a category, which its tab shows.
@(private = "file")
category_first :: proc(cat: proto.Emoji_Category) -> rune {
	for e in proto.EMOJI {
		if e.category == cat {
			return e.r
		}
	}
	return '?'
}

// picked handles a chosen emoji. In a composer it is inserted at the cursor
// (and the picker stays open for more). As a reaction it is sent and the
// picker closes.
@(private = "file")
picked :: proc(ui: ^UI, emoji: string) {
	p := &ui.picker
	if p.react_to != 0 {
		send_reaction(ui, p.react_to, emoji, true)
		p.open = false
		return
	}
	c := composer_of(ui, p.thread)
	at := c.len^
	if ui.ctx.textbox_state.id == u64(mu.get_id(&ui.ctx, uintptr(&c.buf[0]))) {
		at = clamp(ui.ctx.textbox_state.selection[0], 0, c.len^)
	}
	if c.len^ + len(emoji) > len(c.buf) {
		return
	}
	rest := strings.clone(string(c.buf[at:c.len^]), context.temp_allocator)
	n := copy(c.buf[at:], emoji)
	copy(c.buf[at + n:], rest)
	c.len^ += n
	focus_composer(ui, c, at + n)
}
