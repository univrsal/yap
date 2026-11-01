package ui

import "core"
import "titlebar"

import "client:render"
import mu "vendor:microui"

// The window's buttons, and the cursor over the edges that a window without a
// frame is resized by. The platforms' own parts, and the edges, are in
// ui/titlebar.

// The cursor over each edge.
EDGE_CURSORS := [titlebar.Edge]Cursor {
	.None         = .Arrow,
	.Top_Left     = .Resize_NWSE,
	.Top          = .Resize_NS,
	.Top_Right    = .Resize_NESW,
	.Right        = .Resize_EW,
	.Bottom_Right = .Resize_NWSE,
	.Bottom       = .Resize_NS,
	.Bottom_Left  = .Resize_NESW,
	.Left         = .Resize_EW,
}

// window_edge is the edge of the window that the logical point `x, y`
// resizes it by, if any.
window_edge :: proc(ui: ^UI, x, y: i32) -> titlebar.Edge {
	if ui.window == nil {
		return .None
	}
	return titlebar.edge_at(
		titlebar.resizable(ui.window),
		i32(ui.metrics.logical_w),
		i32(ui.metrics.logical_h),
		x,
		y,
	)
}

// The button that the pointer went down on, or -1.
@(private = "file")
g_armed := -1

// window_buttons draws minimize, maximize (or restore) and close in the top
// right corner of the window, `w` wide, in the strip that titlebar.area made
// room for, `gap` window coordinates short of its left end. It returns which
// one was clicked: 0, 1 or 2, or -1 for none.
window_buttons :: proc(ui: ^UI, w: i32, gap: f32, maximized: bool) -> int {
	ctx := &ui.ctx
	size := (ui.titlebar_right - i32(gap * ui.input_scale)) / titlebar.BUTTON_COUNT
	Button :: struct {
		id:   string,
		icon: render.Icon,
	}
	buttons := [titlebar.BUTTON_COUNT]Button {
		{"minimize", .Minimize},
		{"maximize", .Restore if maximized else .Maximize},
		{"close", .Close},
	}
	clicked := -1
	for b, i in buttons {
		id := mu.get_id(ctx, b.id)
		r := mu.Rect{w - size * i32(titlebar.BUTTON_COUNT - i), 0, size, ui.titlebar_height}
		mu.update_control(ctx, id, r)
		if core.nav_control(ctx, id, r) {
			clicked = i
		}
		color := ctx.style.colors[.TEXT]
		if ctx.hover_id == id {
			// Close turns red, as Windows' own does.
			shade := mu.Color{232, 17, 35, 255} if i == 2 else ctx.style.colors[.BUTTON_HOVER]
			mu.draw_rect(ctx, r, shade)
			if i == 2 {
				color = {255, 255, 255, 255}
			}
		}
		mu.draw_icon(ctx, render.icon_id(b.icon), r, color)
		// A button acts when the press is released over it, not when it
		// goes down: closing the window on the press would leave the
		// release for whatever window is behind it.
		if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
			g_armed = i
		}
		if g_armed == i && .LEFT not_in ctx.mouse_down_bits {
			g_armed = -1
			if ctx.hover_id == id {
				clicked = i
			}
		}
	}
	return clicked
}

// titlebar_buttons draws the window's buttons in the top right corner of the
// window, `w` wide, in the strip that titlebar.area made room for, and does
// what they say when pressed. (Where the system draws them, the strip has no
// width and there is nothing to do.)
titlebar_buttons :: proc(ui: ^UI, w: i32) {
	if ui.titlebar_right == 0 {
		return
	}
	maximized := titlebar.is_maximized(ui.window)
	if i := window_buttons(ui, w, titlebar.button_gap(ui.input_scale), maximized); i >= 0 {
		titlebar.click_button(ui.window, i, maximized)
	}
}
