#+build linux, openbsd
package hotkeys

import "core:dynlib"
import "core:os"

// X11 is loaded at runtime instead of being linked, so the client doesn't
// need libX11 to start. It uses a display connection of its own, which is
// only used from the watcher's thread.
@(private)
X11 :: struct {
	lib:          dynlib.Library,
	display:      rawptr,
	query_keymap: proc "c" (display: rawptr, keys: ^[32]u8) -> i32,
	close:        proc "c" (display: rawptr) -> i32,
}

// x11_open loads libX11 as `name` and opens the default display.
@(private)
x11_open :: proc(x: ^X11, name: string) -> bool {
	if os.get_env("DISPLAY", context.temp_allocator) == "" {
		return false
	}
	lib, ok := dynlib.load_library(name)
	if !ok {
		return false
	}
	open_display, open_ok := dynlib.symbol_address(lib, "XOpenDisplay")
	query, query_ok := dynlib.symbol_address(lib, "XQueryKeymap")
	close_display, close_ok := dynlib.symbol_address(lib, "XCloseDisplay")
	if !open_ok || !query_ok || !close_ok {
		dynlib.unload_library(lib)
		return false
	}
	display := (proc "c" (name: cstring) -> rawptr)(open_display)(nil)
	if display == nil {
		dynlib.unload_library(lib)
		return false
	}
	x^ = {
		lib          = lib,
		display      = display,
		query_keymap = auto_cast query,
		close        = auto_cast close_display,
	}
	return true
}

@(private)
x11_close :: proc(x: ^X11) {
	if x.display != nil {
		x.close(x.display)
	}
	if x.lib != nil {
		dynlib.unload_library(x.lib)
	}
	x^ = {}
}

// x11_keymap stores the X server's keymap in `keymap`: a bit for each
// keycode, set while that key is down.
@(private)
x11_keymap :: proc(x: ^X11, keymap: ^[32]u8) -> bool {
	return x.display != nil && x.query_keymap(x.display, keymap) != 0
}
