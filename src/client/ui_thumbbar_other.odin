#+build !windows
package client

import glfw "client:wglfw"

// Only Windows' taskbar has buttons under a window's preview
// (ui_thumbbar_windows.odin).

thumbbar_attach :: proc(window: glfw.WindowHandle) {}

thumbbar_detach :: proc() {}

thumbbar_update :: proc(ui: ^UI) {}
