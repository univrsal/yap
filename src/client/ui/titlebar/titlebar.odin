// What every platform's merged title bar shares (titlebar_darwin.odin,
// titlebar_windows.odin, titlebar_x11.odin): the sizes of the window's buttons
// and the edges that a window without a frame is resized by. It needs the
// window and a few numbers, nothing of the UI's state. Drawing the buttons,
// which does, is ui/titlebar.odin.
//
// Each platform has the same procedures:
//
//	init            before GLFW starts: the platform to ask it for
//	window_hints    before each window is made
//	merge           merge the title bar into the UI, or put it back
//	area            the strip along the top that it took, if merged
//	press           a press on that strip
//	motion          the pointer moving, after such a press
//	button_gap      how far short of the strip's end the buttons start
//	is_maximized    whether the window is maximized
//	click_button    do what one of the window's buttons says
//	resizable       whether edge_at applies
//	resize          a press on one of those edges
//	restart_note    what the setting can't change until a restart
package titlebar

// How wide each of the window's own buttons is, at 96 dpi: the width that
// Windows 10 and 11 give their caption buttons.
BUTTON_WIDTH :: 46
BUTTON_COUNT :: 3

// How far in from the window's edge the pointer resizes it, in logical
// pixels, where that is left to us (resizable).
@(private = "file")
EDGE_SIZE :: 4

Edge :: enum {
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

// edge_at is the edge of a window `w` by `h` (logical pixels) that the logical
// point `x, y` resizes it by, if any. `resizable` is what resizable(window) said.
edge_at :: proc(resizable: bool, w, h, x, y: i32) -> Edge {
	if !resizable {
		return .None
	}
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
