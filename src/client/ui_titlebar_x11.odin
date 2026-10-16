#+build linux
package client

import glfw "client:wglfw"
import log "common:wlog"
import "core:c"
import "core:dynlib"
import "core:os"
import "core:time"
import vglfw "vendor:glfw"

// On X11 the merged title bar is a window without decorations: the UI runs up
// to the top edge, with minimize, maximize and close buttons of its own at the
// end of the first row (see title_row), as on Windows.
//
// With no frame, the window manager no longer moves or resizes the window by
// itself, so we ask it to, as GTK and Qt do for theirs. A press on the strip
// where the title bar was, or on the window's outer few pixels, followed by the
// pointer moving a little with the button held, hands the pointer over to the
// window manager with _NET_WM_MOVERESIZE. The window manager then runs the drag
// until the button is released, with its own snapping, edge tiling and so on.
// The request is not sent on the press itself: a window manager that receives
// the request after the button is already up (a quick click) would treat the
// next click as the end of the drag, and a double click would never reach us.
//
// Wayland has the same request (xdg_toplevel.move and .resize), but GLFW keeps
// the objects it needs to itself, so a window can't send it there. With the
// setting on, a Wayland session gets the client as an X11 window through
// XWayland instead (titlebar_init). This only takes effect when GLFW starts, so
// switching between the two needs a restart.
//
// libX11 is loaded at runtime, as for the clipboard. The request goes through
// GLFW's own connection.

// Room left between the first row and the buttons, in logical pixels.
@(private = "file")
TITLEBAR_GAP :: 8

// Two presses on the strip this close together maximize or restore the window.
@(private = "file")
DOUBLE_CLICK :: 400 * time.Millisecond

// How far the pointer moves with the button held before it counts as a drag,
// in pixels at 96 dpi.
@(private = "file")
DRAG_DISTANCE :: 4

// From the Extended Window Manager Hints.
@(private = "file")
MOVERESIZE_MOVE :: 8
@(private = "file")
CLIENT_MESSAGE :: 33
@(private = "file")
SUBSTRUCTURE_NOTIFY_MASK :: 1 << 19
@(private = "file")
SUBSTRUCTURE_REDIRECT_MASK :: 1 << 20

// XClientMessageEvent, padded out to the size of an XEvent.
@(private = "file")
Client_Message :: struct {
	type:         c.int,
	serial:       c.ulong,
	send_event:   b32,
	display:      rawptr,
	window:       c.ulong,
	message_type: c.ulong,
	format:       c.int,
	data:         [5]c.long,
	_:            [12]c.long,
}
#assert(size_of(Client_Message) == 24 * size_of(c.long))

@(private = "file")
Symbols :: struct {
	__handle:           dynlib.Library,
	XInternAtom:        proc "c" (d: rawptr, name: cstring, only_if_exists: b32) -> c.ulong,
	XDefaultRootWindow: proc "c" (d: rawptr) -> c.ulong,
	XUngrabPointer:     proc "c" (d: rawptr, time: c.ulong) -> c.int,
	XSendEvent:         proc "c" (
		d: rawptr,
		w: c.ulong,
		propagate: b32,
		mask: c.long,
		event: ^Client_Message,
	) -> c.int,
	XFlush:             proc "c" (d: rawptr) -> c.int,
}

@(private = "file")
x11: struct {
	sym:        Symbols,
	tried:      bool,
	loaded:     bool,
	// Whether the client was started on X11 rather than Wayland because of the setting.
	xwayland:   bool,
	last_press: time.Tick,
	// A press on the strip or an edge that becomes a move or resize once the
	// pointer moves (titlebar_motion): which direction, and where.
	pending:    bool,
	direction:  c.long,
	pressed_at: [2]f64,
}

// titlebar_init asks GLFW for X11 rather than Wayland when the title bar is to
// be merged (see above), where there is an X server to ask: under XWayland,
// DISPLAY is set alongside WAYLAND_DISPLAY.
titlebar_init :: proc(merged: bool) {
	if !merged {
		// The compositor draws the title bar, so libdecor (and GTK) isn't
		// needed (see ui_wayland_decorations.odin).
		if wayland_server_decorations() {
			vglfw.InitHint(vglfw.WAYLAND_LIBDECOR, vglfw.WAYLAND_DISABLE_LIBDECOR)
			log.debug("ui: the compositor draws the title bar, so no libdecor")
		}
		return
	}
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" ||
	   os.get_env("DISPLAY", context.temp_allocator) == "" {
		return
	}
	vglfw.InitHint(vglfw.PLATFORM, vglfw.PLATFORM_X11)
	x11.xwayland = true
	log.debug("ui: X11 rather than Wayland, for the merged title bar")
}

// titlebar_window_hints makes the window without decorations from the start,
// rather than removing them once it is up.
titlebar_window_hints :: proc(merged: bool) {
	glfw.WindowHint(vglfw.DECORATED, !(merged && on_x11()))
}

// titlebar_merge lets the UI take the title bar's place, or gives it back.
// Only on X11. On Wayland it takes a restart (titlebar_init).
titlebar_merge :: proc(window: glfw.WindowHandle, merged: bool) {
	if window == nil || !on_x11() {
		return
	}
	if merged == (vglfw.GetWindowAttrib(window, vglfw.DECORATED) == 0) {
		return
	}
	vglfw.SetWindowAttrib(window, vglfw.DECORATED, 0 if merged else 1)
}

// titlebar_area is the strip along the top that the title bar would have
// taken, in window coordinates: how far in from the left and from the right
// the window's own buttons reach (only the right here), and how tall the strip
// is. It is zero where the window manager draws the title bar, or in
// fullscreen.
//
// There is no system title bar to match here, so it is sized in the UI's own
// pixels, as the first row is, and scales with it. It reaches down to where the
// first row ends, so that the buttons keep the same spacing from the second row
// as the rows keep from each other.
titlebar_area :: proc(ui: ^UI) -> (left, right, height: f32) {
	if !merged(ui.window) || ui.input_scale <= 0 {
		return
	}
	style := ui.ctx.style
	row := style.size.y + style.padding * 2 // a row's height (mu.layout_next)
	height = f32(style.padding + row) / ui.input_scale
	right = f32(TITLEBAR_BUTTON_WIDTH * TITLEBAR_BUTTON_COUNT + TITLEBAR_GAP) / ui.input_scale
	return
}

// titlebar_buttons draws the window's buttons in the top right corner of the
// window, `w` wide, in the strip that titlebar_area made room for, and does
// what they say when pressed.
titlebar_buttons :: proc(ui: ^UI, w: i32) {
	if ui.titlebar_right == 0 {
		return
	}
	maximized := vglfw.GetWindowAttrib(ui.window, vglfw.MAXIMIZED) != 0
	switch window_buttons(ui, w, TITLEBAR_GAP / ui.input_scale, maximized) {
	case 0:
		vglfw.IconifyWindow(ui.window)
	case 1:
		if maximized {
			glfw.RestoreWindow(ui.window)
		} else {
			vglfw.MaximizeWindow(ui.window)
		}
	case 2:
		// As the window manager's close button would: the client decides what
		// closing does (ui_frame).
		glfw.SetWindowShouldClose(ui.window, true)
	}
}

// titlebar_press does what a title bar does with the press being handled:
// move the window along with the pointer once it moves (titlebar_motion), or
// maximize or restore it on a double click. Called from the mouse button
// callback. The drag runs until the button is released.
titlebar_press :: proc(window: glfw.WindowHandle) {
	if x11.last_press != {} && time.tick_since(x11.last_press) < DOUBLE_CLICK {
		x11.last_press = {}
		x11.pending = false
		if vglfw.GetWindowAttrib(window, vglfw.MAXIMIZED) != 0 {
			glfw.RestoreWindow(window)
		} else {
			vglfw.MaximizeWindow(window)
		}
		return
	}
	x11.last_press = time.tick_now()
	start_drag(window, MOVERESIZE_MOVE)
}

// titlebar_motion hands a press on the strip or an edge over to the window
// manager once the pointer has moved far enough with the button held. Called
// from the cursor position callback.
titlebar_motion :: proc(window: glfw.WindowHandle) {
	if !x11.pending {
		return
	}
	if vglfw.GetMouseButton(window, vglfw.MOUSE_BUTTON_LEFT) != vglfw.PRESS {
		x11.pending = false
		return
	}
	x, y := glfw.GetCursorPos(window)
	scale, _ := glfw.GetWindowContentScale(window)
	reach := f64(DRAG_DISTANCE * max(scale, 1))
	if abs(x - x11.pressed_at.x) < reach && abs(y - x11.pressed_at.y) < reach {
		return
	}
	x11.pending = false
	move_resize(window, x11.direction)
}

// titlebar_resizable reports whether window_edge resizes the window: it has no
// frame to be resized by, and isn't maximized or fullscreen.
titlebar_resizable :: proc(window: glfw.WindowHandle) -> bool {
	return merged(window) && vglfw.GetWindowAttrib(window, vglfw.MAXIMIZED) == 0
}

// titlebar_resize resizes the window by `edge` while the button is held.
titlebar_resize :: proc(window: glfw.WindowHandle, edge: Window_Edge) {
	// _NET_WM_MOVERESIZE numbers the edges clockwise from the top left, as
	// Window_Edge does from 1.
	if edge != .None {
		start_drag(window, c.long(edge) - 1)
	}
}

@(private = "file")
XWAYLAND_NOTE :: "On Wayland this needs XWayland, which this window will use from the next start."

// titlebar_restart_note says what the setting won't change until the client is
// started again, if anything.
titlebar_restart_note :: proc(merged: bool) -> string {
	switch {
	case merged && on_wayland():
		return XWAYLAND_NOTE
	case !merged && x11.xwayland:
		return "From the next start this window will run on Wayland again."
	}
	return ""
}

@(private = "file")
on_x11 :: proc() -> bool {
	return glfw.GetPlatform() == glfw.PLATFORM_X11
}

// merged reports whether `window` is one that titlebar_merge removed the
// decorations from, and isn't fullscreen.
@(private = "file")
merged :: proc(window: glfw.WindowHandle) -> bool {
	return(
		window != nil &&
		on_x11() &&
		vglfw.GetWindowAttrib(window, vglfw.DECORATED) == 0 &&
		vglfw.GetWindowMonitor(window) == nil \
	)
}

// start_drag notes a press that moves (MOVERESIZE_MOVE) or resizes the window,
// for titlebar_motion.
@(private = "file")
start_drag :: proc(window: glfw.WindowHandle, direction: c.long) {
	x, y := glfw.GetCursorPos(window)
	x11.pending = true
	x11.direction = direction
	x11.pressed_at = {x, y}
}

@(private = "file")
load_x11 :: proc() -> bool {
	if x11.tried {
		return x11.loaded
	}
	x11.tried = true
	s := &x11.sym
	_, ok := dynlib.initialize_symbols(s, "libX11.so.6")
	if !ok {
		_, ok = dynlib.initialize_symbols(s, "libX11.so")
	}
	if !ok ||
	   s.XInternAtom == nil ||
	   s.XDefaultRootWindow == nil ||
	   s.XUngrabPointer == nil ||
	   s.XSendEvent == nil ||
	   s.XFlush == nil {
		log.warn("ui: couldn't load libX11, so the window can't be moved by its title bar")
		return false
	}
	x11.loaded = true
	return true
}

// move_resize hands the pointer to the window manager to move the window
// (MOVERESIZE_MOVE) or resize it by an edge (0 to 7, clockwise from the top
// left) until the left button is released. The press that started it has the
// pointer grabbed for us, so that grab is released first. The window manager
// is told where the press was rather than where the pointer is now, so the
// window keeps to the pointer as it was when pressed.
@(private = "file")
move_resize :: proc(window: glfw.WindowHandle, direction: c.long) {
	display := rawptr(vglfw.GetX11Display())
	if display == nil || !load_x11() {
		return
	}
	s := &x11.sym
	wx, wy := vglfw.GetWindowPos(window)
	px, py := x11.pressed_at.x, x11.pressed_at.y
	event := Client_Message {
		type         = CLIENT_MESSAGE,
		send_event   = true,
		display      = display,
		window       = c.ulong(vglfw.GetX11Window(window)),
		message_type = s.XInternAtom(display, "_NET_WM_MOVERESIZE", false),
		format       = 32,
		// Where the pointer is on the screen, which direction, with which
		// button (the left), and that an application is asking.
		data         = {c.long(wx) + c.long(px), c.long(wy) + c.long(py), direction, 1, 1},
	}
	s.XUngrabPointer(display, 0)
	s.XSendEvent(
		display,
		s.XDefaultRootWindow(display),
		false,
		SUBSTRUCTURE_REDIRECT_MASK | SUBSTRUCTURE_NOTIFY_MASK,
		&event,
	)
	s.XFlush(display)
}
