package client

import "base:intrinsics"
import glfw "client:wglfw"
import NS "core:sys/darwin/Foundation"
import vglfw "vendor:glfw"

/*
On macOS the window has no title bar of its own: the UI runs up to the
top edge, and the close, minimize and zoom buttons sit on it, over the
start of the first row (see title_row). Everywhere else the desktop's
own title bar stays.

What's left of the strip the title bar used to be still moves the
window when dragged and zooms it when double-clicked, as a title bar
would, wherever there's no control of ours under the pointer (see
mouse_button_callback). In fullscreen there's no strip at all.
*/

// NSOpenGLContext, to tell the GL context its view has changed size.
@(private = "file", objc_class = "NSOpenGLContext")
GL_Context :: struct {
	using _: NS.Object,
}

// NSWindowButton's zoom button, the rightmost of the three.
@(private = "file")
ZOOM_BUTTON :: 2

// Room left between the zoom button and the first row, in points.
@(private = "file")
TITLEBAR_GAP :: 8

// titlebar_merge lets the UI take the title bar's place. Called once
// the window has its GL context.
titlebar_merge :: proc(window: glfw.WindowHandle) {
	w := vglfw.GetCocoaWindow(window)
	if w == nil {
		return
	}
	mask := intrinsics.objc_send(NS.WindowStyleMask, w, "styleMask")
	w->setStyleMask(mask + {.FullSizeContentView})
	w->setTitlebarAppearsTransparent(true)
	w->setTitleVisibility(.Hidden)
	// The view under the context just grew by the title bar, which
	// AppKit doesn't pass on to the context by itself.
	if gl := intrinsics.objc_send(^GL_Context, GL_Context, "currentContext"); gl != nil {
		intrinsics.objc_send(nil, gl, "update")
	}
}

/*
titlebar_area is the strip along the top that the title bar would have
taken, in window coordinates: how far in from the left the window's own
buttons reach, and how tall the strip is. Zero in fullscreen, where the
title bar only slides in over the UI when the pointer goes up there.
*/
titlebar_area :: proc(window: glfw.WindowHandle) -> (left, height: f32) {
	w := vglfw.GetCocoaWindow(window)
	if w == nil {
		return
	}
	height = f32(w->frame().size.height - w->contentLayoutRect().size.height)
	if height <= 0 {
		return 0, 0
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

/*
titlebar_press does what a title bar does with the press being handled:
move the window along with the pointer, or, on a double click, whatever
the system settings say a double click on a title bar does. Called from
the mouse button callback, while AppKit's event is still the current
one; the drag runs until the button is let go.
*/
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
