#+build !wasi
package client

import glfw "client:wglfw"
import stbi "client:wstbi"
import log "common:wlog"

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

/*
window_icon_rgba is the window's icon at `side` pixels square, RGBA, for
the tray (ui_tray.odin): each pixel the average of the ones it covers,
weighted by how opaque they are, so the edges don't go dark. nil if
icon.png won't decode. The caller owns the result.
*/
window_icon_rgba :: proc(side: int, allocator := context.allocator) -> []u8 {
	png := ICON_PNG
	w, h, comp: i32
	src := stbi.load_from_memory(raw_data(png), i32(len(png)), &w, &h, &comp, 4)
	if src == nil {
		log.warn("could not decode the window icon")
		return nil
	}
	defer stbi.image_free(src)
	sw, sh := int(w), int(h)
	pixels := make([]u8, side * side * 4, allocator)
	for y in 0 ..< side {
		y0 := y * sh / side
		y1 := max((y + 1) * sh / side, y0 + 1)
		for x in 0 ..< side {
			x0 := x * sw / side
			x1 := max((x + 1) * sw / side, x0 + 1)
			sum: [4]int
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					p := src[(sy * sw + sx) * 4:]
					a := int(p[3])
					sum += {int(p[0]) * a, int(p[1]) * a, int(p[2]) * a, a}
				}
			}
			i := (y * side + x) * 4
			if sum[3] > 0 {
				pixels[i] = u8(sum[0] / sum[3])
				pixels[i + 1] = u8(sum[1] / sum[3])
				pixels[i + 2] = u8(sum[2] / sum[3])
			}
			pixels[i + 3] = u8(sum[3] / ((y1 - y0) * (x1 - x0)))
		}
	}
	return pixels
}
