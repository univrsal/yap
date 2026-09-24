/*
Tray icons (see yap_tray.c and traycon.h, BSD-3-Clause). Build the
library with build.sh / build.bat at the repo root.

One icon, drawn from RGBA pixels, with an optional right-click menu.
The callbacks come back from step, on the thread that calls it, so the
client can treat them as part of its own loop (see ui_tray.odin).

On Linux the icon goes to the desktop's StatusNotifierItem service over
D-Bus, or to an XEmbed tray on X11; create returns nil where there's
neither, which is not an error worth stopping for.
*/
package tray

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_tray.lib"
} else {
	@(private)
	LIB :: "libyap_tray.a"
}

when !#exists(LIB) {
	#panic("src/client/tray/" + LIB + " is missing; build it with build.sh (or build.bat on Windows)")
}

when ODIN_OS == .Windows {
	foreign import lib {LIB, "system:shell32.lib", "system:user32.lib", "system:gdi32.lib"}
} else when ODIN_OS == .Darwin {
	foreign import lib {LIB, "system:Cocoa.framework", "system:UserNotifications.framework"}
} else when ODIN_OS == .Linux {
	// dbus-1 and X11 are dlopen'd at runtime (traycon_dl.h) rather than
	// linked, so yap-client still starts on a desktop missing either;
	// only libdl itself is a real link-time dependency.
	foreign import lib {LIB, "system:dl"}
} else {
	// BSDs fold dlopen/dlsym into libc, so there's no separate lib to link.
	foreign import lib {LIB}
}

Tray :: struct {}

// Which desktop service to put the icon in; Auto tries D-Bus first and
// falls back to an X11 tray. Linux only, and set before create.
Backend :: enum i32 {
	Auto = 0,
	Sni  = 1,
	X11  = 2,
}

// A line in the right-click menu. A nil label draws a separator.
Menu_Item :: struct {
	label: cstring,
	id:    i32, // ours; handed back to the menu callback
	flags: Menu_Flags,
}

Menu_Flag :: enum i32 {
	Disabled, // greyed out
	Checked, // shows a tick
}
Menu_Flags :: distinct bit_set[Menu_Flag;i32]

Notification_Action :: struct {
	id:    cstring, // ours; handed back to the notification callback
	label: cstring, // button text displayed to the user
}

Click_Proc :: #type proc "c" (tray: ^Tray, userdata: rawptr)
Menu_Proc :: #type proc "c" (tray: ^Tray, item_id: i32, userdata: rawptr)
// action_id is the id of the button clicked, or "default" for the
// notification itself.
Notification_Proc :: #type proc "c" (tray: ^Tray, action_id: cstring, userdata: rawptr)

@(default_calling_convention = "c", link_prefix = "traycon_")
foreign lib {
	// nil if the desktop has nowhere to put an icon. The pixels are
	// width * height RGBA bytes, top-left first, and are copied.
	create :: proc(rgba: [^]u8, width, height: i32, cb: Click_Proc, userdata: rawptr) -> ^Tray ---
	// 0 on success, -1 on failure.
	update_icon :: proc(tray: ^Tray, rgba: [^]u8, width, height: i32) -> i32 ---
	// Handles whatever the desktop has sent, without blocking, and calls
	// back into us. 0 normally, -1 once the icon is gone for good.
	step :: proc(tray: ^Tray) -> i32 ---
	destroy :: proc(tray: ^Tray) ---
	set_visible :: proc(tray: ^Tray, visible: b32) -> i32 ---
	// The items are copied; count 0 removes the menu.
	set_menu :: proc(tray: ^Tray, items: [^]Menu_Item, count: i32, cb: Menu_Proc, userdata: rawptr) -> i32 ---
	set_preferred_backend :: proc(backend: Backend) ---
	// A desktop notification (on Linux org.freedesktop.Notifications);
	// body and actions may be nil. 0 on success.
	notify :: proc(tray: ^Tray, title, body: cstring, actions: [^]Notification_Action, count: i32, cb: Notification_Proc, userdata: rawptr) -> i32 ---
}
