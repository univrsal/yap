#+build linux
package client

import "core:c"
import "core:dynlib"
import "core:os"

// On Wayland, GLFW draws the window's title bar through libdecor, whose GTK
// plugin loads all of GTK 3: its libraries, its theme (7.6 MB of CSS on the
// heap), fontconfig's font list and a few threads, about 4.5 MB of the client's
// own memory and 20 MB of libraries (see misc/memory). It does so even where
// the compositor draws title bars itself (KDE, Sway and most others), and lets
// it. Where the compositor offers that (zxdg_decoration_manager_v1), GLFW is
// asked to do without libdecor: the compositor draws the title bar, as it
// would have anyway. Where it doesn't (GNOME, Weston), libdecor stays, since
// GLFW's own decorations are a bare strip without a title or buttons.
//
// That is asked of the compositor before GLFW starts, through a connection of
// our own that is closed again (wayland_server_decorations).

@(private = "file")
Wl_Symbols :: struct {
	__handle:                           dynlib.Library,
	wl_display_connect:                 proc "c" (name: cstring) -> rawptr,
	wl_display_disconnect:              proc "c" (display: rawptr),
	wl_display_roundtrip:               proc "c" (display: rawptr) -> c.int,
	wl_proxy_marshal_array_constructor: proc "c" (
		proxy: rawptr,
		opcode: u32,
		args: [^]u64,
		interface: rawptr,
	) -> rawptr,
	wl_proxy_add_listener:              proc "c" (proxy, implementation, data: rawptr) -> c.int,
	wl_proxy_destroy:                   proc "c" (proxy: rawptr),
	wl_registry_interface:              rawptr, // a struct wl_interface
}

// wl_display.get_registry's opcode.
@(private = "file")
WL_DISPLAY_GET_REGISTRY :: 1

// The wl_registry listener: global and global_remove.
@(private = "file")
Registry_Listener :: struct {
	global:        proc "c" (data, registry: rawptr, name: u32, interface: cstring, version: u32),
	global_remove: proc "c" (data, registry: rawptr, name: u32),
}

// wayland_server_decorations says whether the Wayland compositor we would
// run on draws title bars for windows that ask it to. False when there is
// no Wayland session, or it can't be asked.
wayland_server_decorations :: proc() -> bool {
	if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
		return false
	}
	s: Wl_Symbols
	_, ok := dynlib.initialize_symbols(&s, "libwayland-client.so.0")
	if !ok {
		return false
	}
	defer dynlib.unload_library(s.__handle)
	if s.wl_display_connect == nil ||
	   s.wl_display_disconnect == nil ||
	   s.wl_display_roundtrip == nil ||
	   s.wl_proxy_marshal_array_constructor == nil ||
	   s.wl_proxy_add_listener == nil ||
	   s.wl_proxy_destroy == nil ||
	   s.wl_registry_interface == nil {
		return false
	}
	display := s.wl_display_connect(nil)
	if display == nil {
		return false
	}
	defer s.wl_display_disconnect(display)
	args: [1]u64 // the new registry's id, filled in by libwayland
	registry := s.wl_proxy_marshal_array_constructor(
		display,
		WL_DISPLAY_GET_REGISTRY,
		&args[0],
		s.wl_registry_interface,
	)
	if registry == nil {
		return false
	}
	defer s.wl_proxy_destroy(registry)
	@(static) listener := Registry_Listener {
		global = proc "c" (data, registry: rawptr, name: u32, interface: cstring, version: u32) {
			if string(interface) == "zxdg_decoration_manager_v1" {
				(^bool)(data)^ = true
			}
		},
		global_remove = proc "c" (data, registry: rawptr, name: u32) {},
	}
	found := false
	if s.wl_proxy_add_listener(registry, &listener, &found) != 0 {
		return false
	}
	if s.wl_display_roundtrip(display) < 0 {
		return false
	}
	return found
}
