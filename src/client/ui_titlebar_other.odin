#+build !darwin
#+build !windows
#+build !linux
package client

import glfw "client:wglfw"

// Only macOS, Windows and X11 put the UI in the title bar (see
// ui_titlebar.odin). Everywhere else the desktop's own title bar stays.

titlebar_init :: proc(merged: bool) {}

titlebar_window_hints :: proc(merged: bool) {}

titlebar_merge :: proc(window: glfw.WindowHandle, merged: bool) {}

titlebar_area :: proc(ui: ^UI) -> (left, right, height: f32) {
	return 0, 0, 0
}

titlebar_press :: proc(window: glfw.WindowHandle) {}

titlebar_motion :: proc(window: glfw.WindowHandle) {}

titlebar_buttons :: proc(ui: ^UI, w: i32) {}

titlebar_resizable :: proc(window: glfw.WindowHandle) -> bool {
	return false
}

titlebar_resize :: proc(window: glfw.WindowHandle, edge: Window_Edge) {}

titlebar_restart_note :: proc(merged: bool) -> string {
	return ""
}
