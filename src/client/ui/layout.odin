package ui

import "widgets"
import "core"
import "base:intrinsics"
import mu "vendor:microui"

layout :: proc(ui: ^UI, w, h: i32) {
	ctx := &ui.ctx
	// The server rail down the left (see ui/servers.odin), and one window
	// that always fills the rest of the OS window.
	rail := rail_width(ui)
	ui.narrow = w - rail < NARROW_LAYOUT
	server_rail(ui, h)
	rail_menu(ui)
	if cnt := mu.get_container(ctx, "yap"); cnt != nil {
		cnt.rect = {rail, 0, w - rail, h}
		// Always under the windows that float over it (pins, threads,
		// the picker...). microui raises a clicked window unless its
		// zindex is below 0, and sorts the lowest first.
		cnt.zindex = -1
	}
	// Without a frame: it is in the sidebars' color, and the content's surface
	// is painted over that (content_surface).
	opts := mu.Options{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_CLOSE}
	if mu.begin_window(ctx, "yap", {rail, 0, w - rail, h}, opts) {
		mu.draw_rect(ctx, mu.get_current_container(ctx).rect, core.theme.sidebar)
		titlebar_buttons(ui, w)
		ui.title_line, ui.conv_line = 0, 0
		main_window(ui)
		// Under the title row, from the rail to the window's right edge.
		if ui.title_line > 0 {
			mu.draw_rect(ctx, {rail, ui.title_line, w - rail, 1}, core.theme.divider)
		}
		mu.end_window(ctx)
	}
	// An enlarged image floats above everything else (see ui/images.odin).
	image_viewer(ui, w, h)
	// A screen that is being watched, popped out of its tab (see ui/video.odin).
	screen_window(ui, w, h)
	// The cameras, popped out of the Video tab (see ui/camera.odin).
	camera_window(ui, w, h)
	pins_window(ui, w, h)
	bookmarks_window(ui, w, h)
	thread_windows(ui, w, h)
	profile_windows(ui, w, h)
	completion_window(ui)
	picker_window(ui, w, h)
	channels_window(ui, w, h)
	channel_edit_window(ui, w, h)
	forward_window(ui, w, h)
	group_picker_window(ui, w, h)
	search_window(ui, w, h)
	palette_window(ui, w, h)
	// After every timeline, the thread windows' timelines too.
	message_bar(ui)
	widgets.dropdown_popup(ui, w, h)
	// Last, and in windows of their own, so they are over the popups too.
	chip_preview_popup(ui, w, h)
	icon_hint(ui, w, h)
	drop_hint(ui)
	voice_drag_frame(ui)
}

// content_surface paints the content's surface (theme.content) under the next
// layout cell: a conversation, a settings page, beside the sidebars. It reaches
// halfway into the gaps to the cells around it, and to the window's edges where
// the cell is next to one. It returns the area it painted, for the lines drawn
// along it once the cell has been laid out (conversation_lines).
content_surface :: proc(env: ^core.Env) -> mu.Rect {
	ctx := &env.ctx
	cell := mu.layout_next(ctx)
	mu.layout_set_next(ctx, cell, false)
	win := mu.get_current_container(ctx).rect
	near := ctx.style.padding + 1
	half := ctx.style.spacing / 2
	left := win.x if cell.x - win.x <= near else cell.x - half
	top := win.y if cell.y - win.y <= near else cell.y - half
	right := cell.x + cell.w
	right = win.x + win.w if win.x + win.w - right <= near else right + half
	bottom := cell.y + cell.h
	bottom = win.y + win.h if win.y + win.h - bottom <= near else bottom + half
	r := mu.Rect{left, top, right - left, bottom - top}
	mu.draw_rect(ctx, r, core.theme.content)
	return r
}

// keep_in_window keeps the current window, one that floats over the main window
// and can be dragged by its title bar, inside the OS window and below the
// strip along its top (the merged title bar and its line, UI.title_line), so
// that it can't cover the window's own buttons or be lost off an edge. microui
// moves a dragged window after drawing it, so this takes effect before it is
// drawn again. Call right after mu.begin_window.
keep_in_window :: proc(ui: ^UI) {
	cnt := mu.get_current_container(&ui.ctx)
	w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
	top := ui.titlebar_height
	if ui.title_line > 0 {
		top = max(top, ui.title_line + 1)
	}
	r := &cnt.rect
	r.w, r.h = min(r.w, max(w, 96)), min(r.h, max(h - top, 64))
	r.x = clamp(r.x, 0, max(w - r.w, 0))
	r.y = clamp(r.y, top, max(h - r.h, top))
}

// How much room a conversation's header has above and below its row, and in
// from the left. The search box beside it has the same (search_box).
CONV_HEADER_PAD :: 6

// header_pad is the room above or below a conversation's header: an empty row.
header_pad :: proc(env: ^core.Env) {
	mu.layout_row(&env.ctx, {-1}, CONV_HEADER_PAD)
	mu.layout_next(&env.ctx)
}

// header_line_below ends a conversation's header with the room below it, and
// notes that it has a lighter line under that (conversation_lines), halfway
// into the gap to what follows.
header_line_below :: proc(ui: ^UI) {
	header_pad(ui)
	layout := mu.get_layout(&ui.ctx)
	ui.conv_line = layout.body.y + layout.next_row - ui.ctx.style.spacing / 2
}

// header_surface carries a conversation's surface `r` (content_surface) on
// across the members pinned down the side, along its header, where the search
// box is (search_box). Call after the conversation, before the members.
header_surface :: proc(ui: ^UI, r: mu.Rect) {
	if ui.conv_line <= r.y {
		return
	}
	ctx := &ui.ctx
	win := mu.get_current_container(ctx).rect
	x := r.x + r.w
	mu.draw_rect(ctx, {x, r.y, win.x + win.w - x, ui.conv_line - r.y}, core.theme.content)
}

// conversation_lines draws the lines along a conversation's surface `r`
// (content_surface): the lighter one under its header, from the surface's left
// edge to the window's right one (across the members' column), and with
// `divider`, the one down its right-hand edge between it and the members, from
// there to the bottom.
conversation_lines :: proc(ui: ^UI, r: mu.Rect, divider: bool) {
	ctx := &ui.ctx
	win := mu.get_current_container(ctx).rect
	top := r.y
	if ui.conv_line > 0 {
		top = ui.conv_line
		mu.draw_rect(ctx, {r.x, top, win.x + win.w - r.x, 1}, core.theme.divider_soft)
		top += 1
	}
	if divider {
		mu.draw_rect(ctx, {r.x + r.w, top, 1, r.y + r.h - top}, core.theme.divider)
	}
}

// In a window narrower than this (a phone, or a window squeezed to the side),
// the channels go above the chat instead of beside it.
NARROW_LAYOUT :: 600

// In a window at least this wide, the members are pinned down the right of the
// channel instead of being in a window from the header's button.
MEMBERS_PIN_LAYOUT :: 1100
MEMBERS_PANEL_WIDTH :: 240

// How roomy controls are: microui's padding inside them and spacing between
// them, and the size of its controls (a row is size.y + 2 * padding tall).
// microui's own are 5, 4 and 68x10. On a phone, rows are 40 px tall, as big as
// a fingertip, and closer together, to leave room for the messages.
STYLE_PADDING :: 6
STYLE_SPACING :: 6
STYLE_SIZE :: mu.Vec2{80, 14}
COMPACT_PADDING :: 6
COMPACT_SPACING :: 4
COMPACT_SIZE :: mu.Vec2{80, 28}

// On a phone, the messages (the timeline) are spaced as microui's own
// controls are, closer than elsewhere: there is little room for them.
COMPACT_MESSAGE_PADDING :: 5
COMPACT_MESSAGE_SPACING :: 4

// style_apply sets microui's sizes for this frame, a window `width` wide: for
// a finger where the window is as narrow as a phone's (as session_screen
// tells it, beside the rail) or a touch screen has been used.
style_apply :: proc(ui: ^UI, width: i32) {
	ui.compact = width - RAIL_WIDTH < NARROW_LAYOUT || ui.touched
	style := ui.ctx.style
	if ui.compact {
		style.padding, style.spacing, style.size = COMPACT_PADDING, COMPACT_SPACING, COMPACT_SIZE
	} else {
		style.padding, style.spacing, style.size = STYLE_PADDING, STYLE_SPACING, STYLE_SIZE
	}
}

// titlebar_merged says whether the window's buttons are drawn in the top row
// of our own layout (ui/titlebar.odin) rather than in a title bar of the
// system's, which shows the window's title.
titlebar_merged :: proc(ui: ^UI) -> bool {
	return ui.titlebar_left > 0 || ui.titlebar_right > 0
}

// title_row is mu.layout_row for a screen's first row. With the title bar
// merged, that row shares the top of the window with the window's buttons
// (see ui/titlebar.odin), so it keeps clear of them. On macOS the buttons are on
// the left, so the row starts to the right of them. On Windows and X11 they are
// on the right, so widths counted from the right-hand edge are counted
// from the buttons instead.
//
// With the title bar merged, a line goes under the row (see UI.title_line).
title_row :: proc(ui: ^UI, widths: []i32, height: i32 = 0) {
	layout := mu.get_layout(&ui.ctx)
	if titlebar_merged(ui) && ui.title_line == 0 {
		// Halfway into the gap under the row, where the content's surface
		// starts (content_surface). A row of height 0 is a control's height.
		style := ui.ctx.style
		h := height if height > 0 else style.size.y + 2 * style.padding
		ui.title_line = layout.body.y + layout.next_row + h + style.spacing - style.spacing / 2
	}
	indent := layout.indent
	layout.indent += max(ui.titlebar_left - layout.body.x, 0)
	if ui.titlebar_right == 0 {
		mu.layout_row(&ui.ctx, widths, height)
	} else {
		kept_clear := make([]i32, len(widths), context.temp_allocator)
		for w, i in widths {
			kept_clear[i] = w <= 0 ? w - ui.titlebar_right : w
		}
		mu.layout_row(&ui.ctx, kept_clear, height)
	}
	layout.indent = indent
}
