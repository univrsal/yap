#+build openbsd
package hotkeys

import "core:c"
import "core:dynlib"
import "core:os"

/*
On OpenBSD there are no evdev devices to read, so it's X11's
XQueryKeymap: the X server's view of the keyboard, whatever has the
focus.

Its keycodes aren't Linux's (OpenBSD's X uses the ws driver, with the
older xfree86 set), so rather than a table of them, the keyboard's XKB
key names are asked for once. Those name physical positions - <AC01> is
where A is on a US layout, <FK01> is F1 - on every keycode set, which is
just what a Key is.

libX11 is loaded when it's needed rather than linked, as on Linux, and
the connection is our own, used only from the watcher's thread.
*/

// The XKB name of each key's position (xkeyboard-config's keycodes).
@(private = "file")
KEY_NAMES := [Key]string {
	.None          = "",
	.A             = "AC01",
	.B             = "AB05",
	.C             = "AB03",
	.D             = "AC03",
	.E             = "AD03",
	.F             = "AC04",
	.G             = "AC05",
	.H             = "AC06",
	.I             = "AD08",
	.J             = "AC07",
	.K             = "AC08",
	.L             = "AC09",
	.M             = "AB07",
	.N             = "AB06",
	.O             = "AD09",
	.P             = "AD10",
	.Q             = "AD01",
	.R             = "AD04",
	.S             = "AC02",
	.T             = "AD05",
	.U             = "AD07",
	.V             = "AB04",
	.W             = "AD02",
	.X             = "AB02",
	.Y             = "AD06",
	.Z             = "AB01",
	.Num_1         = "AE01",
	.Num_2         = "AE02",
	.Num_3         = "AE03",
	.Num_4         = "AE04",
	.Num_5         = "AE05",
	.Num_6         = "AE06",
	.Num_7         = "AE07",
	.Num_8         = "AE08",
	.Num_9         = "AE09",
	.Num_0         = "AE10",
	.F1            = "FK01",
	.F2            = "FK02",
	.F3            = "FK03",
	.F4            = "FK04",
	.F5            = "FK05",
	.F6            = "FK06",
	.F7            = "FK07",
	.F8            = "FK08",
	.F9            = "FK09",
	.F10           = "FK10",
	.F11           = "FK11",
	.F12           = "FK12",
	.F13           = "FK13",
	.F14           = "FK14",
	.F15           = "FK15",
	.F16           = "FK16",
	.F17           = "FK17",
	.F18           = "FK18",
	.F19           = "FK19",
	.F20           = "FK20",
	.F21           = "FK21",
	.F22           = "FK22",
	.F23           = "FK23",
	.F24           = "FK24",
	.Space         = "SPCE",
	.Enter         = "RTRN",
	.Tab           = "TAB",
	.Escape        = "ESC",
	.Backspace     = "BKSP",
	.Insert        = "INS",
	.Delete        = "DELE",
	.Home          = "HOME",
	.End           = "END",
	.Page_Up       = "PGUP",
	.Page_Down     = "PGDN",
	.Up            = "UP",
	.Down          = "DOWN",
	.Left          = "LEFT",
	.Right         = "RGHT",
	.Minus         = "AE11",
	.Equal         = "AE12",
	.Left_Bracket  = "AD11",
	.Right_Bracket = "AD12",
	.Backslash     = "BKSL",
	.Semicolon     = "AC10",
	.Apostrophe    = "AC11",
	.Grave         = "TLDE",
	.Comma         = "AB08",
	.Period        = "AB09",
	.Slash         = "AB10",
	.Pause         = "PAUS",
	.Scroll_Lock   = "SCLK",
	.Print_Screen  = "PRSC",
}

// Both sides of each modifier.
@(private = "file")
MOD_NAMES := [Mod][2]string {
	.Ctrl  = {"LCTL", "RCTL"},
	.Shift = {"LFSH", "RTSH"},
	.Alt   = {"LALT", "RALT"},
	.Super = {"LWIN", "RWIN"},
}

// From X11/extensions/XKB.h.
@(private = "file")
XKB_KEY_NAMES_MASK :: 1 << 9
@(private = "file")
XKB_USE_CORE_KBD :: 0x0100

// The parts of XkbDescRec and XkbNamesRec (X11/extensions/XKBstr.h)
// that are read, laid out as they are up to there.
@(private = "file")
Xkb_Desc :: struct {
	dpy:          rawptr,
	flags:        u16,
	device_spec:  u16,
	min_key_code: u8,
	max_key_code: u8,
	ctrls:        rawptr,
	server:       rawptr,
	client_map:   rawptr,
	indicators:   rawptr,
	names:        ^Xkb_Names,
}

@(private = "file")
Xkb_Names :: struct {
	keycodes:   c.ulong,
	geometry:   c.ulong,
	symbols:    c.ulong,
	types:      c.ulong,
	compat:     c.ulong,
	vmods:      [16]c.ulong,
	indicators: [32]c.ulong,
	groups:     [4]c.ulong,
	keys:       [^][4]u8, // indexed by keycode, up to max_key_code
}

Backend :: struct {
	lib:          dynlib.Library,
	display:      rawptr,
	query_keymap: proc "c" (display: rawptr, keys: ^[32]u8) -> i32,
	close:        proc "c" (display: rawptr) -> i32,
	// The keycode at each position; 0 where the keyboard has none.
	key_codes:    [Key]u8,
	mod_codes:    [Mod][2]u8,
}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	if !x11_open(b) {
		return .Unavailable, "No X11 display."
	}
	return .Ok, "Using X11."
}

backend_close :: proc(b: ^Backend) {
	if b.display != nil {
		b.close(b.display)
	}
	if b.lib != nil {
		dynlib.unload_library(b.lib)
	}
	b^ = {}
}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {
	keymap: [32]u8
	if b.display == nil || b.query_keymap(b.display, &keymap) == 0 {
		return
	}
	down :: proc(keymap: ^[32]u8, code: u8) -> bool {
		return code != 0 && keymap[code / 8] & (1 << (code % 8)) != 0
	}
	for key in wanted {
		if down(&keymap, b.key_codes[key]) {
			s.keys += {key}
		}
	}
	for codes, mod in b.mod_codes {
		if down(&keymap, codes[0]) || down(&keymap, codes[1]) {
			s.mods += {mod}
		}
	}
}

// Nothing comes and goes on X11 the way keyboards do on Linux.
backend_status :: proc(b: ^Backend) -> (Status, string, bool) {
	if b.display == nil {
		return .Unavailable, "No X11 display.", false
	}
	return .Ok, "Using X11.", false
}

@(private = "file")
x11_open :: proc(b: ^Backend) -> bool {
	if os.get_env("DISPLAY", context.temp_allocator) == "" {
		return false
	}
	// OpenBSD versions libX11 differently (libX11.so.19.0); its loader
	// finds the newest for the bare name.
	lib, ok := dynlib.load_library("libX11.so")
	if !ok {
		return false
	}
	open_display, open_ok := dynlib.symbol_address(lib, "XOpenDisplay")
	query, query_ok := dynlib.symbol_address(lib, "XQueryKeymap")
	close_display, close_ok := dynlib.symbol_address(lib, "XCloseDisplay")
	get_map, map_ok := dynlib.symbol_address(lib, "XkbGetMap")
	get_names, names_ok := dynlib.symbol_address(lib, "XkbGetNames")
	free_keyboard, free_ok := dynlib.symbol_address(lib, "XkbFreeKeyboard")
	if !open_ok || !query_ok || !close_ok || !map_ok || !names_ok || !free_ok {
		dynlib.unload_library(lib)
		return false
	}
	display := (proc "c" (name: cstring) -> rawptr)(open_display)(nil)
	if display == nil {
		dynlib.unload_library(lib)
		return false
	}
	b.lib = lib
	b.display = display
	b.query_keymap = auto_cast query
	b.close = auto_cast close_display

	// Where each key is, from the keyboard's key names: a description
	// of the core keyboard (for its range of keycodes), then its names.
	desc := (proc "c" (display: rawptr, which, device_spec: c.uint) -> ^Xkb_Desc)(get_map)(
		display,
		0,
		XKB_USE_CORE_KBD,
	)
	if desc == nil {
		backend_close(b)
		return false
	}
	defer (proc "c" (desc: ^Xkb_Desc, which: c.uint, free_desc: b32))(free_keyboard)(desc, 0, true)
	status := (proc "c" (display: rawptr, which: c.uint, desc: ^Xkb_Desc) -> c.int)(get_names)(
		display,
		XKB_KEY_NAMES_MASK,
		desc,
	)
	if status != 0 || desc.names == nil || desc.names.keys == nil {
		backend_close(b)
		return false
	}
	for code in int(desc.min_key_code) ..= int(desc.max_key_code) {
		name := key_name(&desc.names.keys[code])
		for want, key in KEY_NAMES {
			if want != "" && name == want {
				b.key_codes[key] = u8(code)
			}
		}
		for sides, mod in MOD_NAMES {
			for side, i in sides {
				if name == side {
					b.mod_codes[mod][i] = u8(code)
				}
			}
		}
	}
	return true
}

// key_name is an XKB key name as a string: up to four characters,
// padded with NULs when shorter.
@(private = "file")
key_name :: proc(name: ^[4]u8) -> string {
	n := 0
	for n < len(name) && name[n] != 0 {
		n += 1
	}
	return string(name[:n])
}
