#+build !darwin
#+build !windows
package client

import glfw "client:wglfw"

// Only macOS and Windows put the UI in the title bar (see
// ui_titlebar_darwin.odin, ui_titlebar_windows.odin); everywhere else the
// desktop's own stays where it is.

titlebar_merge :: proc(window: glfw.WindowHandle) {}

titlebar_area :: proc(window: glfw.WindowHandle) -> (left, right, height: f32) {
	return 0, 0, 0
}

titlebar_press :: proc(window: glfw.WindowHandle) {}

titlebar_buttons :: proc(ui: ^UI, w: i32) {}
