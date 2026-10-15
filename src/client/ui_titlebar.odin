package client

import "client:render"
import mu "vendor:microui"

// What every platform's merged title bar shares (ui_titlebar_darwin.odin,
// ui_titlebar_windows.odin, ui_titlebar_x11.odin): the window's buttons, on
// platforms that have none of their own, and the edges that a window without
// a frame is resized by.
//
// Each platform has the same procedures:
//
//	titlebar_init           before GLFW starts: the platform to ask it for
//	titlebar_window_hints   before each window is made
//	titlebar_merge          merge the title bar into the UI, or put it back
//	titlebar_area           the strip along the top that it took, if merged
//	titlebar_press          a press on that strip
//	titlebar_motion         the pointer moving, after such a press
//	titlebar_buttons        draw the window's buttons, where it has to
//	titlebar_resizable      whether window_edge applies
//	titlebar_resize         a press on one of those edges
//	titlebar_restart_note   what the setting can't change until a restart

// How wide each of the window's own buttons is, at 96 dpi: the width that
// Windows 10 and 11 give their caption buttons.
TITLEBAR_BUTTON_WIDTH :: 46
TITLEBAR_BUTTON_COUNT :: 3

// How far in from the window's edge the pointer resizes it, in logical
// pixels, where that is left to us (titlebar_resizable).
@(private = "file")
EDGE_SIZE :: 4

Window_Edge :: enum {
	None,
	Top_Left,
	Top,
	Top_Right,
	Right,
	Bottom_Right,
	Bottom,
	Bottom_Left,
	Left,
}

// The cursor over each edge.
EDGE_CURSORS := [Window_Edge]Cursor {
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
window_edge :: proc(ui: ^UI, x, y: i32) -> Window_Edge {
	if ui.window == nil || !titlebar_resizable(ui.window) {
		return .None
	}
	w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
	if x < 0 || y < 0 || x >= w || y >= h {
		return .None
	}
	left, right := x < EDGE_SIZE, x >= w - EDGE_SIZE
	top, bottom := y < EDGE_SIZE, y >= h - EDGE_SIZE
	switch {
	case top && left:
		return .Top_Left
	case top && right:
		return .Top_Right
	case bottom && left:
		return .Bottom_Left
	case bottom && right:
		return .Bottom_Right
	case top:
		return .Top
	case bottom:
		return .Bottom
	case left:
		return .Left
	case right:
		return .Right
	}
	return .None
}

// window_buttons draws minimize, maximize (or restore) and close in the top
// right corner of the window, `w` wide, in the strip that titlebar_area made
// room for, `gap` window coordinates short of its left end. It returns which
// one was clicked: 0, 1 or 2, or -1 for none.
window_buttons :: proc(ui: ^UI, w: i32, gap: f32, maximized: bool) -> int {
	ctx := &ui.ctx
	size := (ui.titlebar_right - i32(gap * ui.input_scale)) / TITLEBAR_BUTTON_COUNT
	Button :: struct {
		id:   string,
		icon: render.Icon,
	}
	buttons := [TITLEBAR_BUTTON_COUNT]Button {
		{"minimize", .Minimize},
		{"maximize", .Restore if maximized else .Maximize},
		{"close", .Close},
	}
	clicked := -1
	for b, i in buttons {
		id := mu.get_id(ctx, b.id)
		r := mu.Rect{w - size * i32(TITLEBAR_BUTTON_COUNT - i), 0, size, ui.titlebar_height}
		mu.update_control(ctx, id, r)
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
		if ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id {
			clicked = i
		}
	}
	return clicked
}
