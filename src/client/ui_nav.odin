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

Nav_Item :: struct {
	id:       mu.Id,
	rect:     mu.Rect,
	root:     ^mu.Container, // the root container it is drawn in (nil outside any)
	text_len: int, // a text box's text length, where the cursor goes; -1 for others
}

UI_Nav :: struct {
	focus:    mu.Id,
	visible:  bool,
	items:    [dynamic]Nav_Item, // this frame's controls, in draw order
	// Enter or Space was pressed on this control in the last frame: it acts
	// as if clicked in this one.
	activate: mu.Id,
	// A popup on top (a dropdown's list): Tab, Up and Down only move among
	// the controls in it. Set in every frame it is drawn in (nav_trap).
	trap:     ^mu.Container,
	// What gets the focus back once the focused control is gone: the
	// dropdown whose list was opened from the keyboard.
	return_to: mu.Id,
}

// nav_trap keeps the keyboard focus inside the current root container (a
// popup) for this frame.
nav_trap :: proc(ui: ^UI) {
	ui.nav.trap = mu.get_current_container(&ui.ctx)
}

ui_nav_destroy :: proc(ui: ^UI) {
	delete(ui.nav.items)
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

// nav_control makes the control `id` in `r` one that Tab stops at, draws the
// outline around it while it has the keyboard focus, and says whether Enter
// or Space pressed it. A text box passes its text's length as `text_len`.
nav_control :: proc(ctx: ^mu.Context, id: mu.Id, r: mu.Rect, text_len := -1) -> (activated: bool) {
	n := nav_of(ctx)
	if n == nil {
		return false
	}
	root: ^mu.Container
	if ctx.container_stack.idx > 0 {
		root = ctx.container_stack.items[0]
	}
	append(&n.items, Nav_Item{id, r, root, text_len})
	if n.visible && n.focus == id {
		render.draw_rounded_outside(ctx, r, theme.accent, render.CONTROL_RADIUS, border = true)
	}
	return n.activate == id
}

// nav_focused says whether `id` has the keyboard focus, shown.
nav_focused :: proc(ctx: ^mu.Context, id: mu.Id) -> bool {
	n := nav_of(ctx)
	return n != nil && n.visible && n.focus == id
}

// nav_frame moves the keyboard focus with this frame's keys, after the layout
// and before mu.end (which forgets what the mouse and Enter did, and keeps
// the text box focus set here).
nav_frame :: proc(ui: ^UI) {
	n := &ui.nav
	ctx := &ui.ctx
	trap := n.trap
	defer {
		clear(&n.items)
		n.trap = nil
	}
	n.activate = 0
	if ctx.mouse_pressed_bits != {} {
		n.focus, n.visible, n.return_to = 0, false, 0
		return
	}
	items := n.items[:]
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
		// The popup that had the focus closed.
		n.focus, n.return_to = n.return_to, 0
		at = nav_index(items, n.focus)
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
	switch {
	case (forward || back) && len(items) > 0:
		next := nav_step(len(items), at, back)
		it := items[next]
		n.focus, n.visible = it.id, true
		if it.text_len >= 0 {
			focus_at(ctx, it.id, it.text_len)
		} else if nav_index(n.items[:], ctx.focus_id) >= 0 {
			mu.set_focus(ctx, 0) // out of the text box
		}
		ui_redraw(ui)
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

// nav_focus_next gives the keyboard focus to the control `id`, drawn
// later in this frame, if the keyboard focus is shown (a popup opened from
// the keyboard focuses its first control). Its opener gets it back when it
// closes.
nav_focus_next :: proc(ui: ^UI, id: mu.Id) {
	n := &ui.nav
	if n.visible {
		n.return_to = n.focus
		n.focus = id
	}
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
