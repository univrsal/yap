#+build !darwin
#+build !windows
#+build !linux
package titlebar

import glfw "client:wglfw"

// Only macOS, Windows and X11 put the UI in the title bar (see
// ui/titlebar.odin). Everywhere else the desktop's own title bar stays.

init :: proc(merged: bool) {}

window_hints :: proc(merged: bool) {}

merge :: proc(window: glfw.WindowHandle, merged: bool) {}

area :: proc(window: glfw.WindowHandle, input_scale: f32, padding, size_y: i32) -> (left, right, height: f32) {
	return 0, 0, 0
}

press :: proc(window: glfw.WindowHandle) {}

motion :: proc(window: glfw.WindowHandle) {}

button_gap :: proc(input_scale: f32) -> f32 {
	return 0
}

is_maximized :: proc(window: glfw.WindowHandle) -> bool {
	return false
}

click_button :: proc(window: glfw.WindowHandle, i: int, maximized: bool) {}

resizable :: proc(window: glfw.WindowHandle) -> bool {
	return false
}

resize :: proc(window: glfw.WindowHandle, edge: Edge) {}

restart_note :: proc(merged: bool) -> string {
	return ""
}
