#+build !wasi
package client

import log "../common/wlog"
import glfw "wglfw"
import stbi "wstbi"

/*
The window's icon, for the title bar and the taskbar, from
assets/icon.png. Only Windows and X11 take one from the program: on
macOS a window has no icon of its own (the Dock shows the app's), and on
Wayland the desktop finds it through the app's .desktop entry - GLFW
reports both as errors, so they're left alone. A web build has the
page's favicon instead (web/build.sh).

On Windows the .exe carries icon.ico as well (see build.bat), which
Explorer shows and GLFW uses until this replaces it.
*/

// Also what install_self installs as the icon on Linux and macOS.
ICON_PNG :: #load("assets/icon.png")

set_window_icon :: proc(window: glfw.WindowHandle) {
	when ODIN_OS == .Darwin {
		return
	}
	if glfw.GetPlatform() == glfw.PLATFORM_WAYLAND {
		return
	}
	png := ICON_PNG
	w, h, comp: i32
	pixels := stbi.load_from_memory(raw_data(png), i32(len(png)), &w, &h, &comp, 4)
	if pixels == nil {
		log.warn("could not decode the window icon")
		return
	}
	defer stbi.image_free(pixels)
	// GLFW copies the pixels, so they needn't outlive the call.
	glfw.SetWindowIcon(window, {{width = w, height = h, pixels = pixels}})
}
