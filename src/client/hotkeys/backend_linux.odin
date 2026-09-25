#+build linux
package hotkeys

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:time"

/*
On Linux the keyboards themselves say which of their keys are down:
every /dev/input/event* device that has letter keys is opened, and each
turn their key state is read with EVIOCGKEY. Nothing is grabbed, and no
events are read, so they all still go wherever they were going. This is
below any display server, so it works the same on Wayland and X11 - but
the devices usually belong to the "input" group, and only its members
(and root) may read them.

Without them, on X11, XQueryKeymap does the same for the X server's view
of the keyboard. Under Wayland that's XWayland's view, which only has
keys while an X11 window has the focus, so it's reported as Limited.

Keyboards come and go (a USB or Bluetooth one), so the devices are
looked for again every RESCAN_INTERVAL, and one that stops answering is
closed.
*/

@(private = "file")
RESCAN_INTERVAL :: 3 * time.Second
// /dev/input/event0 up to this; there are a few dozen on a busy system.
@(private = "file")
MAX_EVENT_DEVICES :: 64

// From linux/input.h and linux/input-event-codes.h.
@(private = "file")
EV_KEY :: 0x01
@(private = "file")
KEY_MAX :: 0x2ff
@(private = "file")
KEY_BYTES :: (KEY_MAX + 8) / 8

// _IOC(_IOC_READ, 'E', nr, size), for the evdev ioctls that read.
@(private = "file")
eviocg :: proc(nr: u32, size: u32) -> u32 {
	return 2 << 30 | size << 16 | u32('E') << 8 | nr
}

@(private = "file")
EVIOCGKEY :: 0x18 // the keys down now
@(private = "file")
EVIOCGBIT :: 0x20 // + event type: which codes of that type the device has

@(private = "file")
KEY_CODES := [Key]u16 {
	.None          = 0,
	.A             = 30,
	.B             = 48,
	.C             = 46,
	.D             = 32,
	.E             = 18,
	.F             = 33,
	.G             = 34,
	.H             = 35,
	.I             = 23,
	.J             = 36,
	.K             = 37,
	.L             = 38,
	.M             = 50,
	.N             = 49,
	.O             = 24,
	.P             = 25,
	.Q             = 16,
	.R             = 19,
	.S             = 31,
	.T             = 20,
	.U             = 22,
	.V             = 47,
	.W             = 17,
	.X             = 45,
	.Y             = 21,
	.Z             = 44,
	.Num_1         = 2,
	.Num_2         = 3,
	.Num_3         = 4,
	.Num_4         = 5,
	.Num_5         = 6,
	.Num_6         = 7,
	.Num_7         = 8,
	.Num_8         = 9,
	.Num_9         = 10,
	.Num_0         = 11,
	.F1            = 59,
	.F2            = 60,
	.F3            = 61,
	.F4            = 62,
	.F5            = 63,
	.F6            = 64,
	.F7            = 65,
	.F8            = 66,
	.F9            = 67,
	.F10           = 68,
	.F11           = 87,
	.F12           = 88,
	.F13           = 183,
	.F14           = 184,
	.F15           = 185,
	.F16           = 186,
	.F17           = 187,
	.F18           = 188,
	.F19           = 189,
	.F20           = 190,
	.F21           = 191,
	.F22           = 192,
	.F23           = 193,
	.F24           = 194,
	.Space         = 57,
	.Enter         = 28,
	.Tab           = 15,
	.Escape        = 1,
	.Backspace     = 14,
	.Insert        = 110,
	.Delete        = 111,
	.Home          = 102,
	.End           = 107,
	.Page_Up       = 104,
	.Page_Down     = 109,
	.Up            = 103,
	.Down          = 108,
	.Left          = 105,
	.Right         = 106,
	.Minus         = 12,
	.Equal         = 13,
	.Left_Bracket  = 26,
	.Right_Bracket = 27,
	.Backslash     = 43,
	.Semicolon     = 39,
	.Apostrophe    = 40,
	.Grave         = 41,
	.Comma         = 51,
	.Period        = 52,
	.Slash         = 53,
	.Pause         = 119,
	.Scroll_Lock   = 70,
	.Print_Screen  = 99,
}

// Both sides of each modifier.
@(private = "file")
MOD_CODES := [Mod][2]u16 {
	.Ctrl  = {29, 97},
	.Shift = {42, 54},
	.Alt   = {56, 100},
	.Super = {125, 126},
}

// What a keyboard is taken to be: something with these keys.
@(private = "file")
KEYBOARD_KEYS :: [?]u16{30, 44, 57} // A, Z, Space

@(private = "file")
Key_Bits :: [KEY_BYTES]u8

@(private = "file")
bit :: proc(bits: ^Key_Bits, code: u16) -> bool {
	return bits[code / 8] & (1 << (code % 8)) != 0
}

@(private = "file")
Keyboard :: struct {
	index: int, // /dev/input/event<index>
	fd:    linux.Fd,
}

@(private = "file")
Mode :: enum {
	None,
	Evdev,
	X11,
}

Backend :: struct {
	mode:      Mode,
	keyboards: [dynamic]Keyboard,
	last_scan: time.Tick,
	denied:    bool, // an event device couldn't be opened for want of permission
	x11:       X11,
	// What backend_status last said.
	status:    Status,
	message:   string,
}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	scan(b)
	switch {
	case len(b.keyboards) > 0:
		b.mode = .Evdev
	case x11_open(&b.x11):
		b.mode = .X11
	}
	b.status, b.message = describe(b)
	return b.status, b.message
}

backend_close :: proc(b: ^Backend) {
	for k in b.keyboards {
		linux.close(k.fd)
	}
	delete(b.keyboards)
	x11_close(&b.x11)
	b^ = {}
}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {
	down: Key_Bits
	switch b.mode {
	case .None:
		return
	case .Evdev:
		if time.tick_since(b.last_scan) >= RESCAN_INTERVAL {
			scan(b)
		}
		for i := 0; i < len(b.keyboards); {
			k := b.keyboards[i]
			bits: Key_Bits
			if int(linux.ioctl(k.fd, eviocg(EVIOCGKEY, KEY_BYTES), uintptr(&bits))) < 0 {
				// Unplugged, most likely.
				linux.close(k.fd)
				unordered_remove(&b.keyboards, i)
				continue
			}
			for byte, j in bits {
				down[j] |= byte
			}
			i += 1
		}
	case .X11:
		if !x11_query(&b.x11, &down) {
			return
		}
	}

	for key in wanted {
		if bit(&down, KEY_CODES[key]) {
			s.keys += {key}
		}
	}
	for codes, mod in MOD_CODES {
		if bit(&down, codes[0]) || bit(&down, codes[1]) {
			s.mods += {mod}
		}
	}
}

// backend_status says what's changed since it last did (a keyboard
// plugged in, say).
backend_status :: proc(b: ^Backend) -> (st: Status, message: string, changed: bool) {
	st, message = describe(b)
	changed = st != b.status || message != b.message
	b.status, b.message = st, message
	return
}

@(private = "file")
describe :: proc(b: ^Backend) -> (Status, string) {
	switch b.mode {
	case .Evdev:
		if len(b.keyboards) == 0 {
			return .Limited, "No keyboard found (plug one in, or check /dev/input)."
		}
		return .Ok, "Reading the keyboards directly (evdev)."
	case .X11:
		if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
			return .Limited, "Only while an X11 window has the focus: for Wayland, add yourself to the \"input\" group and log in again."
		}
		return .Ok, "Using X11."
	case .None:
	}
	if b.denied {
		return .Unavailable, "Can't read the keyboards: add yourself to the \"input\" group and log in again."
	}
	return .Unavailable, "No keyboard found in /dev/input, and no X11 display."
}

// scan opens every keyboard not already open.
@(private = "file")
scan :: proc(b: ^Backend) {
	b.last_scan = time.tick_now()
	outer: for index in 0 ..< MAX_EVENT_DEVICES {
		for k in b.keyboards {
			if k.index == index {
				continue outer
			}
		}
		path_buf: [32]u8
		path := fmt.bprintf(path_buf[:len(path_buf) - 1], "/dev/input/event%d", index)
		fd, err := linux.open(cstring(raw_data(path)), {.NONBLOCK, .CLOEXEC})
		#partial switch err {
		case .NONE:
		case .EACCES, .EPERM:
			b.denied = true
			continue
		case:
			continue
		}
		if !is_keyboard(fd) {
			linux.close(fd)
			continue
		}
		append(&b.keyboards, Keyboard{index, fd})
	}
}

@(private = "file")
is_keyboard :: proc(fd: linux.Fd) -> bool {
	types: [4]u8
	if int(linux.ioctl(fd, eviocg(EVIOCGBIT, size_of(types)), uintptr(&types))) < 0 ||
	   types[0] & (1 << EV_KEY) == 0 {
		return false
	}
	keys: Key_Bits
	if int(linux.ioctl(fd, eviocg(EVIOCGBIT + EV_KEY, KEY_BYTES), uintptr(&keys))) < 0 {
		return false
	}
	for code in KEYBOARD_KEYS {
		if !bit(&keys, code) {
			return false
		}
	}
	return true
}

/*
X11, loaded when it's needed rather than linked, so the client doesn't
need libX11 to start. It gets a display connection of its own, used only
from the watcher's thread. X11 keycodes are evdev's plus 8, with the
evdev driver every X server has used for years.
*/
@(private = "file")
X11 :: struct {
	lib:          dynlib.Library,
	display:      rawptr,
	query_keymap: proc "c" (display: rawptr, keys: ^[32]u8) -> i32,
	close:        proc "c" (display: rawptr) -> i32,
}

@(private = "file")
x11_open :: proc(x: ^X11) -> bool {
	if os.get_env("DISPLAY", context.temp_allocator) == "" {
		return false
	}
	lib, ok := dynlib.load_library("libX11.so.6")
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

@(private = "file")
x11_close :: proc(x: ^X11) {
	if x.display != nil {
		x.close(x.display)
	}
	if x.lib != nil {
		dynlib.unload_library(x.lib)
	}
	x^ = {}
}

// x11_query puts the X server's keys, as evdev codes, in `down`.
@(private = "file")
x11_query :: proc(x: ^X11, down: ^Key_Bits) -> bool {
	keymap: [32]u8
	if x.display == nil || x.query_keymap(x.display, &keymap) == 0 {
		return false
	}
	for keycode in 8 ..< 256 {
		if keymap[keycode / 8] & (1 << uint(keycode % 8)) != 0 {
			code := keycode - 8
			down[code / 8] |= 1 << uint(code % 8)
		}
	}
	return true
}
