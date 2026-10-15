#+build !wasi
package hotkeys

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Global hotkeys are key combinations that work no matter which window has
// the focus, even when our window is minimized or hidden in the tray.
//
// This does not install a hook that the system calls on every key press.
// Instead, each platform can tell which keys are currently down, and a
// thread asks for that every POLL_INTERVAL (see the backend_*.odin files).
// A bind fires when its key goes down while exactly its modifiers are
// held, so Ctrl+M doesn't also fire for Ctrl+Shift+M. Key presses still
// reach the focused window, so other programs are not affected.
//
//	Windows   GetAsyncKeyState
//	Linux     the keyboards' own state, from /dev/input/event* (evdev),
//	          which works under Wayland as well as X11 but needs read
//	          access to those devices (the "input" group). If that isn't
//	          possible, X11's XQueryKeymap is used instead.
//	OpenBSD   X11's XQueryKeymap
//	macOS    CGEventSourceKeyState, which may need the Input Monitoring
//	          permission
//
// Only the keys of an ordinary keyboard (Key) are supported, with Ctrl,
// Shift, Alt and Super (on either side) as modifiers. Keys are physical
// positions, named as on a US layout, except on Windows, where letters
// follow the active keyboard layout.

Key :: enum u8 {
	None,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	Space,
	Enter,
	Tab,
	Escape,
	Backspace,
	Insert,
	Delete,
	Home,
	End,
	Page_Up,
	Page_Down,
	Up,
	Down,
	Left,
	Right,
	Minus,
	Equal,
	Left_Bracket,
	Right_Bracket,
	Backslash,
	Semicolon,
	Apostrophe,
	Grave,
	Comma,
	Period,
	Slash,
	Pause,
	Scroll_Lock,
	Print_Screen,
}

Keys :: distinct bit_set[Key;u128]

Mod :: enum u8 {
	Ctrl,
	Shift,
	Alt,
	Super, // Windows key, Command on a Mac
}

Mods :: distinct bit_set[Mod;u8]

// A key together with the modifiers that have to be held with it.
// A `key` of .None means there is no hotkey.
Hotkey :: struct {
	key:  Key,
	mods: Mods,
}

// What a backend reports: the keys and modifiers that are down right now.
State :: struct {
	keys: Keys,
	mods: Mods,
}

// How a bind is written in the settings and shown on screen.
KEY_NAMES := [Key]string {
	.None          = "",
	.A             = "A",
	.B             = "B",
	.C             = "C",
	.D             = "D",
	.E             = "E",
	.F             = "F",
	.G             = "G",
	.H             = "H",
	.I             = "I",
	.J             = "J",
	.K             = "K",
	.L             = "L",
	.M             = "M",
	.N             = "N",
	.O             = "O",
	.P             = "P",
	.Q             = "Q",
	.R             = "R",
	.S             = "S",
	.T             = "T",
	.U             = "U",
	.V             = "V",
	.W             = "W",
	.X             = "X",
	.Y             = "Y",
	.Z             = "Z",
	.Num_0         = "0",
	.Num_1         = "1",
	.Num_2         = "2",
	.Num_3         = "3",
	.Num_4         = "4",
	.Num_5         = "5",
	.Num_6         = "6",
	.Num_7         = "7",
	.Num_8         = "8",
	.Num_9         = "9",
	.F1            = "F1",
	.F2            = "F2",
	.F3            = "F3",
	.F4            = "F4",
	.F5            = "F5",
	.F6            = "F6",
	.F7            = "F7",
	.F8            = "F8",
	.F9            = "F9",
	.F10           = "F10",
	.F11           = "F11",
	.F12           = "F12",
	.F13           = "F13",
	.F14           = "F14",
	.F15           = "F15",
	.F16           = "F16",
	.F17           = "F17",
	.F18           = "F18",
	.F19           = "F19",
	.F20           = "F20",
	.F21           = "F21",
	.F22           = "F22",
	.F23           = "F23",
	.F24           = "F24",
	.Space         = "Space",
	.Enter         = "Enter",
	.Tab           = "Tab",
	.Escape        = "Escape",
	.Backspace     = "Backspace",
	.Insert        = "Insert",
	.Delete        = "Delete",
	.Home          = "Home",
	.End           = "End",
	.Page_Up       = "PageUp",
	.Page_Down     = "PageDown",
	.Up            = "Up",
	.Down          = "Down",
	.Left          = "Left",
	.Right         = "Right",
	.Minus         = "-",
	.Equal         = "=",
	.Left_Bracket  = "[",
	.Right_Bracket = "]",
	.Backslash     = "\\",
	.Semicolon     = ";",
	.Apostrophe    = "'",
	.Grave         = "`",
	.Comma         = ",",
	.Period        = ".",
	.Slash         = "/",
	.Pause         = "Pause",
	.Scroll_Lock   = "ScrollLock",
	.Print_Screen  = "PrintScreen",
}

// Modifiers are always written in this order, no matter in which order they
// were typed.
MOD_NAMES := [Mod]string {
	.Ctrl  = "Ctrl",
	.Shift = "Shift",
	.Alt   = "Alt",
	.Super = "Super",
}

// Alternative names for the modifiers that are accepted when reading a bind.
@(private = "file")
Mod_Alias :: struct {
	name: string,
	mod:  Mod,
}

@(private = "file")
MOD_ALIASES := [?]Mod_Alias {
	{"control", .Ctrl},
	{"option", .Alt},
	{"win", .Super},
	{"cmd", .Super},
	{"command", .Super},
	{"meta", .Super},
}

// format writes a hotkey as "Ctrl+Shift+M", or "" for none.
format :: proc(h: Hotkey, allocator := context.allocator) -> string {
	if h.key == .None {
		return ""
	}
	b := strings.builder_make(allocator)
	for mod in Mod {
		if mod in h.mods {
			strings.write_string(&b, MOD_NAMES[mod])
			strings.write_byte(&b, '+')
		}
	}
	strings.write_string(&b, KEY_NAMES[h.key])
	return strings.to_string(b)
}

// parse reads what format writes. It ignores case and spaces and also accepts
// Control, Option, Win, Cmd, Command and Meta as modifier names.
// "" is valid and means no hotkey; anything else must end in exactly one key.
parse :: proc(s: string) -> (h: Hotkey, ok: bool) {
	rest := strings.trim_space(s)
	if rest == "" {
		return {}, true
	}
	// No key is called "+", so it only ever separates.
	for {
		i := strings.index_byte(rest, '+')
		if i < 0 {
			h.key = key_named(strings.trim_space(rest)) or_return
			return h, true
		}
		h.mods += {mod_named(strings.trim_space(rest[:i])) or_return}
		rest = rest[i + 1:]
	}
}

@(private = "file")
key_named :: proc(word: string) -> (Key, bool) {
	for name, key in KEY_NAMES {
		if key != .None && strings.equal_fold(name, word) {
			return key, true
		}
	}
	return .None, false
}

@(private = "file")
mod_named :: proc(word: string) -> (Mod, bool) {
	for name, mod in MOD_NAMES {
		if strings.equal_fold(name, word) {
			return mod, true
		}
	}
	for alias in MOD_ALIASES {
		if strings.equal_fold(alias.name, word) {
			return alias.mod, true
		}
	}
	return {}, false
}

// How often the keys are checked. A longer interval could miss a quick tap
// entirely, and a shorter one would just waste CPU time.
POLL_INTERVAL :: 10 * time.Millisecond

MAX_BINDS :: 8

Status :: enum {
	Starting,
	Ok, // working
	Limited, // working, but not everywhere (see the message)
	Unavailable, // not working (see the message)
}

// Watcher is the thread that checks the keys, together with the state it
// shares with whoever asked for the hotkeys. Everything but `thread` is
// protected by `mutex`.
Watcher :: struct {
	mutex:     sync.Mutex,
	binds:     [MAX_BINDS]Hotkey,
	fired:     u32, // a bit per bind that fired since the last take_fired
	// While capturing, the next key to go down is taken as a new hotkey
	// instead of firing anything.
	capturing: bool,
	captured:  Maybe(Hotkey),
	status:    Status,
	message:   string, // explains why, for Limited and Unavailable; static
	stop:      bool,
	// Called from the watcher's thread when something is waiting to be taken,
	// to wake whoever takes it (glfw.PostEmptyEvent).
	wake:      proc "c" (),
	prev:      State,
	thread:    ^thread.Thread,
}

start :: proc(w: ^Watcher, wake: proc "c" () = nil) {
	w.wake = wake
	w.thread = thread.create_and_start_with_poly_data(w, run, init_context = context)
}

stop :: proc(w: ^Watcher) {
	if w.thread == nil {
		return
	}
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
}

set_bind :: proc(w: ^Watcher, index: int, h: Hotkey) {
	sync.guard(&w.mutex)
	w.binds[index] = h
}

// take_fired returns the binds that have fired since the last call (one bit
// per bind) and clears them.
take_fired :: proc(w: ^Watcher) -> (fired: u32) {
	sync.guard(&w.mutex)
	fired, w.fired = w.fired, 0
	return
}

// capture makes the next key that is pressed (with its modifiers) the result
// of take_captured instead of firing a bind, until it is turned off.
capture :: proc(w: ^Watcher, on: bool) {
	sync.guard(&w.mutex)
	w.capturing, w.captured = on, nil
}

take_captured :: proc(w: ^Watcher) -> (h: Hotkey, ok: bool) {
	sync.guard(&w.mutex)
	h, ok = w.captured.?
	w.captured = nil
	return
}

capturing :: proc(w: ^Watcher) -> bool {
	sync.guard(&w.mutex)
	return w.capturing
}

status :: proc(w: ^Watcher) -> (Status, string) {
	sync.guard(&w.mutex)
	return w.status, w.message
}

@(private = "file")
run :: proc(w: ^Watcher) {
	b: Backend
	st, message := backend_open(&b)
	defer backend_close(&b)
	{
		sync.guard(&w.mutex)
		w.status, w.message = st, message
	}

	for {
		wanted: Keys
		{
			sync.guard(&w.mutex)
			if w.stop {
				return
			}
			wanted = wanted_keys(w)
		}
		cur: State
		backend_poll(&b, &cur, wanted)
		if now, now_message, changed := backend_status(&b); changed {
			{
				sync.guard(&w.mutex)
				w.status, w.message = now, now_message
			}
			if w.wake != nil {
				w.wake()
			}
		}
		woke: bool
		{
			sync.guard(&w.mutex)
			woke = step(w, cur)
		}
		if woke && w.wake != nil {
			w.wake()
		}
		time.sleep(POLL_INTERVAL)
	}
}

// wanted_keys returns the keys a backend needs to check: the bound keys, or
// every key while capturing. Call with the mutex held.
@(private = "file")
wanted_keys :: proc(w: ^Watcher) -> (keys: Keys) {
	if w.capturing {
		return ~Keys{} - {.None}
	}
	for b in w.binds {
		if b.key != .None {
			keys += {b.key}
		}
	}
	return
}

// step processes the current key state. A bind fires when its key has just
// gone down while exactly its modifiers are held. While capturing, the key
// that went down is captured instead. It returns whether there is anything
// to take. Call with the mutex held.
step :: proc(w: ^Watcher, cur: State) -> (woke: bool) {
	pressed := cur.keys - w.prev.keys
	w.prev = cur
	if pressed == {} {
		return false
	}
	if w.capturing {
		for key in pressed {
			w.captured = Hotkey{key, cur.mods}
			w.capturing = false
			return true
		}
	}
	for b, i in w.binds {
		if b.key != .None && b.key in pressed && cur.mods == b.mods {
			w.fired |= 1 << u32(i)
			woke = true
		}
	}
	return
}
