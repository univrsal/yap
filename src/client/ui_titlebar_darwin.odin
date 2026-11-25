package client

import "base:intrinsics"
import "client:render"
import glfw "client:wglfw"
import "core:math"
import NS "core:sys/darwin/Foundation"
import mu "vendor:microui"
import vglfw "vendor:glfw"

// On macOS the window has no title bar of its own: the UI runs up to the top
// edge, and the close, minimize and zoom buttons sit on it, over the start of
// the first row (see title_row). On other platforms the desktop's own title bar
// stays, or on X11 goes (ui_titlebar_x11.odin).
//
// What is left of the strip that the title bar used to be still moves the
// window when dragged and zooms it when double-clicked, as a title bar would,
// wherever there is no control of ours under the pointer (see
// mouse_button_callback). In fullscreen there is no strip at all.

// NSWindowButton's zoom button, the rightmost of the three.
@(private = "file")
ZOOM_BUTTON :: 2

// Room left between the zoom button and the first row, in points.
@(private = "file")
TITLEBAR_GAP :: 8

// Room left between the buttons and the slanted edge of the rail's extension
// (titlebar_buttons), in points.
@(private = "file")
SLANT_GAP :: 3

// titlebar_merge lets the UI take the title bar's place, or gives it back.
// Called once the window has its Metal layer, and when the setting changes.
// The view changes size with it, and the next frame's drawable changes with
// that (render/gpu_metal.odin).
titlebar_merge :: proc(window: glfw.WindowHandle, merged: bool) {
	w := vglfw.GetCocoaWindow(window)
	if w == nil {
		return
	}
	mask := intrinsics.objc_send(NS.WindowStyleMask, w, "styleMask")
	if merged == (.FullSizeContentView in mask) {
		return
	}
	if merged {
		mask += {.FullSizeContentView}
	} else {
		mask -= {.FullSizeContentView}
	}
	w->setStyleMask(mask)
	w->setTitlebarAppearsTransparent(NS.BOOL(merged))
	w->setTitleVisibility(.Hidden if merged else .Visible)
}

// titlebar_area is the strip along the top that the title bar would have
// taken, in window coordinates: how far in from the left and from the right
// the window's own buttons reach (only the left here), and how tall the strip
// is. It is zero in fullscreen, where the title bar only slides in over the UI
// when the pointer goes up there.
titlebar_area :: proc(ui: ^UI) -> (left, right, height: f32) {
	w := vglfw.GetCocoaWindow(ui.window)
	if w == nil ||
	   .FullSizeContentView not_in intrinsics.objc_send(NS.WindowStyleMask, w, "styleMask") {
		return
	}
	height = f32(w->frame().size.height - w->contentLayoutRect().size.height)
	if height <= 0 {
		return 0, 0, 0
	}
	if zoom := intrinsics.objc_send(
		^NS.View,
		w,
		"standardWindowButton:",
		NS.UInteger(ZOOM_BUTTON),
	); zoom != nil {
		left = f32(NS.MaxX(intrinsics.objc_send(NS.Rect, zoom, "frame"))) + TITLEBAR_GAP
	}
	return
}

// titlebar_press does what a title bar does with the press being handled:
// move the window along with the pointer or, on a double click, whatever the
// system settings say a double click on a title bar does. Called from the
// mouse button callback while AppKit's event is still the current one. The drag
// runs until the button is released.
titlebar_press :: proc(window: glfw.WindowHandle) {
	w := vglfw.GetCocoaWindow(window)
	event := NS.Application.sharedApplication()->currentEvent()
	if w == nil || event == nil {
		return
	}
	if event->clickCount() < 2 {
		intrinsics.objc_send(nil, w, "performWindowDragWithEvent:", event)
		return
	}
	defaults := NS.UserDefaults.standardUserDefaults()
	action := intrinsics.objc_send(
		^NS.String,
		defaults,
		"stringForKey:",
		NS.AT("AppleActionOnDoubleClick"),
	)
	switch {
	case action == nil:
		w->performZoom()
	case action->isEqualToString(NS.AT("Minimize")):
		intrinsics.objc_send(nil, w, "miniaturize:", rawptr(nil))
	case action->isEqualToString(NS.AT("None")):
	case:
		w->performZoom()
	}
}

// The slanted edge's slant (across per down) of the rail's extension.
@(private = "file")
SLANT :: f32(0.9)

// The buttons are the system's here, and so are the window's edges. They are
// wider than the rail, so the rail reaches out under them along the strip: a
// quad from the rail's edge, straight along the strip's bottom, whose right
// edge slants out towards the top (SLANT), keeping SLANT_GAP clear of the zoom
// button. Drawn in the main window, over its background and under the rest.
titlebar_buttons :: proc(ui: ^UI, w: i32) {
	if ui.titlebar_left <= 0 || ui.titlebar_height <= 0 {
		return
	}
	win := vglfw.GetCocoaWindow(ui.window)
	if win == nil {
		return
	}
	zoom := intrinsics.objc_send(
		^NS.View,
		win,
		"standardWindowButton:",
		NS.UInteger(ZOOM_BUTTON),
	)
	if zoom == nil {
		return
	}
	// The button in the window's coordinates, which start at the bottom.
	bounds := intrinsics.objc_send(NS.Rect, zoom, "bounds")
	frame := intrinsics.objc_send(NS.Rect, zoom, "convertRect:toView:", bounds, rawptr(nil))
	scale := ui.input_scale
	// The button as a circle, grown by the gap, in logical pixels from the top.
	cx := f32(NS.MidX(frame)) * scale
	cy := f32(win->frame().size.height - NS.MidY(frame)) * scale
	radius := (f32(frame.size.width) / 2 + SLANT_GAP) * scale
	rail := f32(rail_width(ui))
	bottom := f32(ui.titlebar_height)
	if cx + radius <= rail {
		return // the rail clears the buttons by itself
	}
	// Where the slanted edge that touches the circle on its right meets the
	// strip's bottom; from there it goes up and out to the strip's top.
	foot := cx - SLANT * (bottom - cy) + radius * math.sqrt(1 + SLANT * SLANT)
	x := i32(math.ceil(max(foot, rail)))
	r := i32(rail)
	if x > r {
		mu.draw_rect(&ui.ctx, {r, 0, x - r, ui.titlebar_height}, theme.rail)
	}
	width := i32(math.ceil(SLANT * bottom))
	render.draw_slant(&ui.ctx, {x, 0, width, ui.titlebar_height}, theme.rail)
}

titlebar_init :: proc(merged: bool) {}

titlebar_window_hints :: proc(merged: bool) {}

titlebar_motion :: proc(window: glfw.WindowHandle) {}

titlebar_resizable :: proc(window: glfw.WindowHandle) -> bool {
	return false
}

titlebar_resize :: proc(window: glfw.WindowHandle, edge: Window_Edge) {}

titlebar_restart_note :: proc(merged: bool) -> string {
	return ""
}

// The window's frame is outside its client area here, as CreateWindow expects.
titlebar_client_rect :: proc(window: glfw.WindowHandle, x, y, w, h: i32) -> (i32, i32, i32, i32) {
	return x, y, w, h
}
