#+build !darwin
package client

import glfw "client:wglfw"

// Only macOS puts the UI in the title bar (see ui_titlebar_darwin.odin);
// everywhere else the desktop's own stays where it is.

titlebar_merge :: proc(window: glfw.WindowHandle) {}

titlebar_area :: proc(window: glfw.WindowHandle) -> (left, height: f32) {
	return 0, 0
}

titlebar_press :: proc(window: glfw.WindowHandle) {}
