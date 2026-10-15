#+build !windows
package client

import glfw "client:wglfw"

// Only the Windows taskbar has buttons under a window's preview
// (ui_thumbbar_windows.odin), so these do nothing elsewhere.

thumbbar_attach :: proc(window: glfw.WindowHandle) {}

thumbbar_detach :: proc() {}

thumbbar_update :: proc(ui: ^UI) {}
