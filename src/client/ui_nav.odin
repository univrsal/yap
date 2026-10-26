package client

import mu "vendor:microui"

import "client:render"

// Moving through the UI with the keyboard (docs/design/keyboard.md).
//
// Tab and Shift+Tab move a focus of our own through the controls that were
// drawn in the last frame, in the order they were drawn; Enter or Space
// presses the focused one. microui's focus_id can't carry it: a control
// without HOLD_FOCUS gives it up as soon as the mouse button is up. Only on
// a text box does it set focus_id too, since that is what makes the box take
// typing.
//
// The widgets say that they can be focused through nav_control, after
// mu.update_control. The outline only shows once the keyboard has been
// used, and a click hides it again.
//
// A popup (a menu, a dropdown's list) keeps Tab inside it until it closes.
// A window or popup opened from the keyboard gets the focus, and what opened
// it gets it back when it closes. F6 and Shift+F6 move between areas: the
// rail, the main window and the windows over it.

Nav_Item :: struct {
	id:       mu.Id,
	rect:     mu.Rect,
	root:     ^mu.Container, // the root container it is drawn in (nil outside any)
	cnt:      ^mu.Container, // the container that scrolls it (a panel or its root)
	text_len: int, // a text box's text length, where the cursor goes; -1 for others
}

UI_Nav :: struct {
	focus:     mu.Id,
	visible:   bool,
	items:     [dynamic]Nav_Item, // this frame's controls, in draw order
	// Enter or Space was pressed on this control in the last frame: it acts
	// as if clicked in this one.
	activate:  mu.Id,
	// The frame in which a control was last pressed from the keyboard, and
	// the root containers that had controls in the last frame: a window or
	// popup that it opens gets the focus.
	pressed:   mu.Frame_Index,
	roots:     [dynamic]^mu.Container,
	// A popup on top: Tab, Up and Down only move among the controls in it.
	// Set in every frame it is drawn in (nav_trap).
	trap:      ^mu.Container,
	// What gets the focus back once the focused control is gone: what opened
	// the window or popup that has it.
	return_to: mu.Id,
}

// A window opened from the keyboard may first be drawn a frame after the
// control that opened it.
@(private = "file")
NAV_OPEN_FRAMES :: 2

// nav_trap keeps the keyboard focus inside the current root container (a
// popup) for this frame.
nav_trap :: proc(ui: ^UI) {
	ui.nav.trap = nav_root(&ui.ctx)
}

// begin_popup is mu.begin_popup (ended with mu.end_popup), with the
// keyboard focus kept inside the popup and Escape closing it.
begin_popup :: proc(ui: ^UI, name: string) -> bool {
	ctx := &ui.ctx
	if !mu.begin_popup(ctx, name) {
		return false
	}
	if key_take(ui, .Escape) {
		mu.get_current_container(ctx).open = false
	} else {
		nav_trap(ui)
	}
	return true
}

ui_nav_destroy :: proc(ui: ^UI) {
	delete(ui.nav.items)
	delete(ui.nav.roots)
}

// nav_of is the keyboard focus that goes with `ctx`, or nil for a context
// outside the UI (as in tests).
@(private = "file")
nav_of :: proc(ctx: ^mu.Context) -> ^UI_Nav {
	if g_ui == nil || &g_ui.ctx != ctx {
		return nil
	}
	return &g_ui.nav
}

// nav_root is the root container (a window or a popup) being drawn in: the
// innermost one, since a popup may be begun inside another window.
@(private = "file")
nav_root :: proc(ctx: ^mu.Context) -> ^mu.Container {
	roots := ctx.root_list.items[:ctx.root_list.idx]
	#reverse for c in ctx.container_stack.items[:ctx.container_stack.idx] {
		for r in roots {
			if r == c {
				return c
			}
		}
	}
	return nil
}

// nav_control makes the control `id` in `r` one that Tab stops at, draws the
// outline around it while it has the keyboard focus, and says whether Enter
// or Space pressed it. A text box passes its text's length as `text_len`.
nav_control :: proc(ctx: ^mu.Context, id: mu.Id, r: mu.Rect, text_len := -1) -> (activated: bool) {
	n := nav_of(ctx)
	if n == nil {
		return false
	}
	cnt: ^mu.Container
	if ctx.container_stack.idx > 0 {
		cnt = mu.get_current_container(ctx)
	}
	append(&n.items, Nav_Item{id, r, nav_root(ctx), cnt, text_len})
	if n.visible && n.focus == id {
		render.draw_rounded_outside(ctx, r, theme.accent, render.CONTROL_RADIUS, border = true)
	}
	return n.activate == id
}

// nav_activated says whether Enter or Space pressed `id`, for a control
// that has to know before it is drawn.
nav_activated :: proc(ctx: ^mu.Context, id: mu.Id) -> bool {
	n := nav_of(ctx)
	return n != nil && n.activate == id
}

// nav_focused says whether `id` has the keyboard focus, shown.
nav_focused :: proc(ctx: ^mu.Context, id: mu.Id) -> bool {
	n := nav_of(ctx)
	return n != nil && n.visible && n.focus == id
}

// nav_focus_next gives the keyboard focus to the control `id`, drawn
// later in this frame, if the keyboard focus is shown (a dropdown opened
// from the keyboard starts at the current choice). Its opener gets it back
// when it closes.
nav_focus_next :: proc(ui: ^UI, id: mu.Id) {
	n := &ui.nav
	if n.visible {
		n.return_to = n.focus
		n.focus = id
		n.pressed = 0
	}
}

// nav_frame moves the keyboard focus with this frame's keys, after the layout
// and before mu.end (which forgets what the mouse and Enter did, and keeps
// the text box focus set here).
nav_frame :: proc(ui: ^UI) {
	n := &ui.nav
	ctx := &ui.ctx
	trap := n.trap
	all := n.items[:]
	defer {
		clear(&n.roots)
		for it, i in n.items {
			if it.root != nil && nav_first_in(n.items[:], it.root) == i {
				append(&n.roots, it.root)
			}
		}
		clear(&n.items)
		n.trap = nil
	}
	if n.activate != 0 {
		n.pressed = ctx.frame
		n.activate = 0
	}
	if ctx.mouse_pressed_bits != {} {
		n.focus, n.visible, n.return_to, n.pressed = 0, false, 0, 0
		return
	}
	// A window or popup that the keyboard opened gets the focus.
	if n.visible && n.pressed != 0 && ctx.frame - n.pressed <= NAV_OPEN_FRAMES {
		if r := nav_new_root(all, n.roots[:]); r != nil && !nav_focus_in(n, all, r) {
			n.pressed = 0
			n.return_to = n.focus
			nav_move(ui, all[nav_first_in(all, r)])
		}
	}
	items := all
	if trap != nil {
		inside := make([dynamic]Nav_Item, 0, len(items), context.temp_allocator)
		for it in items {
			if it.root == trap {
				append(&inside, it)
			}
		}
		items = inside[:]
	}
	at := nav_index(items, n.focus)
	if at < 0 && n.return_to != 0 {
		// The window or popup that had the focus closed: back to its opener.
		if back := nav_index(items, n.return_to); back >= 0 {
			nav_move(ui, items[back])
			at = back
		}
		n.return_to = 0
	}
	if at < 0 {
		// The focused control is gone (the page changed, a popup closed).
		n.focus, n.visible = 0, false
		// From the text box that was clicked, if there is one.
		at = nav_index(items, ctx.focus_id)
	}
	forward := key_take(ui, .Tab)
	back := key_take(ui, .Back_Tab)
	if trap != nil && n.visible {
		forward |= key_take(ui, .Down)
		back |= key_take(ui, .Up)
	}
	next_area := key_take(ui, .Next_Area)
	prev_area := key_take(ui, .Prev_Area)
	switch {
	case (forward || back) && len(items) > 0:
		nav_move(ui, items[nav_step(len(items), at, back)])
	case (next_area || prev_area) && trap == nil && len(items) > 0:
		nav_move(ui, items[nav_area_step(items, at, prev_area)])
	case n.visible && at >= 0 && items[at].text_len < 0:
		if .Activate in ui.keys || .RETURN in ctx.key_pressed_bits {
			n.activate = n.focus
			ui_redraw(ui)
		}
		if trap == nil && key_take(ui, .Escape) {
			n.focus, n.visible = 0, false
		}
	}
}

// nav_move gives the keyboard focus to `it`, shown, and scrolls it into view.
@(private = "file")
nav_move :: proc(ui: ^UI, it: Nav_Item) {
	n := &ui.nav
	ctx := &ui.ctx
	if it.text_len >= 0 {
		focus_at(ctx, it.id, it.text_len)
	} else if ctx.focus_id != 0 && nav_index(n.items[:], ctx.focus_id) >= 0 {
		mu.set_focus(ctx, 0) // out of the text box
	}
	n.focus, n.visible = it.id, true
	if c := it.cnt; c != nil {
		// As far as it sticks out above or below the container's body.
		pad := ctx.style.padding
		top := it.rect.y - pad
		bottom := it.rect.y + it.rect.h + pad
		if top < c.body.y {
			c.scroll.y = max(c.scroll.y - (c.body.y - top), 0)
		} else if bottom > c.body.y + c.body.h {
			c.scroll.y += bottom - (c.body.y + c.body.h)
		}
	}
	ui_redraw(ui)
}

// nav_new_root is the topmost root container among `items` that had no
// controls in the last frame (`before`), or nil.
@(private = "file")
nav_new_root :: proc(items: []Nav_Item, before: []^mu.Container) -> (top: ^mu.Container) {
	outer: for it in items {
		if it.root == nil {
			continue
		}
		for c in before {
			if c == it.root {
				continue outer
			}
		}
		if top == nil || it.root.zindex > top.zindex {
			top = it.root
		}
	}
	return
}

// nav_focus_in says whether the focused control is in the root `r`.
@(private = "file")
nav_focus_in :: proc(n: ^UI_Nav, items: []Nav_Item, r: ^mu.Container) -> bool {
	at := nav_index(items, n.focus)
	return at >= 0 && items[at].root == r
}

// nav_first_in is where the first control in the root `r` is among `items`,
// or -1.
@(private = "file")
nav_first_in :: proc(items: []Nav_Item, r: ^mu.Container) -> int {
	for it, i in items {
		if it.root == r {
			return i
		}
	}
	return -1
}

// nav_area_step is where F6 goes from `at` among `items` (Shift+F6 with
// `back`): the first control of the next area, a root container (the rail,
// the main window, a window over it), in the order they were first drawn
// in, wrapping around.
nav_area_step :: proc(items: []Nav_Item, at: int, back: bool) -> int {
	starts := make([dynamic]int, 0, 8, context.temp_allocator)
	cur := -1
	for it, i in items {
		if nav_first_in(items, it.root) != i {
			continue
		}
		if at >= 0 && items[at].root == it.root {
			cur = len(starts)
		}
		append(&starts, i)
	}
	return starts[nav_step(len(starts), cur, back)]
}

// nav_index is where `id` is among `items`, or -1.
@(private = "file")
nav_index :: proc(items: []Nav_Item, id: mu.Id) -> int {
	if id == 0 {
		return -1
	}
	for it, i in items {
		if it.id == id {
			return i
		}
	}
	return -1
}

// nav_step is the item after `at` among `n` (before it with `back`),
// wrapping around. With nothing focused (`at` -1), it is the first or the last.
nav_step :: proc(n, at: int, back: bool) -> int {
	if at < 0 {
		return n - 1 if back else 0
	}
	return (at + n - 1) % n if back else (at + 1) % n
}

// key_take takes `k` out of this frame's keys and says whether it was there,
// so that whoever uses a key first is the only one to see it.
key_take :: proc(ui: ^UI, k: Extra_Key) -> bool {
	if k not_in ui.keys {
		return false
	}
	ui.keys -= {k}
	return true
}
