#+build darwin
package hotkeys

/*
On macOS CGEventSourceKeyState says whether a key is down, by its
virtual keycode, which names a position on the keyboard (kVK_ANSI_A is
where A is on a US layout).

Since 10.15, watching the keyboard while another program has the focus
needs the Input Monitoring permission. CGRequestListenEventAccess asks
for it (once; macOS remembers the answer), and until it's given the keys
simply never read as down, which the status says.

Apple keyboards have no Pause, Scroll Lock, Print Screen or F21-F24;
those are never down here.
*/

foreign import cg "system:CoreGraphics.framework"

@(private = "file")
Event_Source_State :: enum i32 {
	Combined_Session = 0,
	HID_System       = 1,
}

@(private = "file", default_calling_convention = "c")
foreign cg {
	CGEventSourceKeyState :: proc(state: Event_Source_State, key: u16) -> b8 ---
	CGPreflightListenEventAccess :: proc() -> b8 ---
	CGRequestListenEventAccess :: proc() -> b8 ---
}

// No such key on a Mac.
@(private = "file")
NONE :: 0xFFFF

@(private = "file")
KVK_CODES := [Key]u16 {
	.None          = NONE,
	.A             = 0x00,
	.S             = 0x01,
	.D             = 0x02,
	.F             = 0x03,
	.H             = 0x04,
	.G             = 0x05,
	.Z             = 0x06,
	.X             = 0x07,
	.C             = 0x08,
	.V             = 0x09,
	.B             = 0x0B,
	.Q             = 0x0C,
	.W             = 0x0D,
	.E             = 0x0E,
	.R             = 0x0F,
	.Y             = 0x10,
	.T             = 0x11,
	.Num_1         = 0x12,
	.Num_2         = 0x13,
	.Num_3         = 0x14,
	.Num_4         = 0x15,
	.Num_6         = 0x16,
	.Num_5         = 0x17,
	.Equal         = 0x18,
	.Num_9         = 0x19,
	.Num_7         = 0x1A,
	.Minus         = 0x1B,
	.Num_8         = 0x1C,
	.Num_0         = 0x1D,
	.Right_Bracket = 0x1E,
	.O             = 0x1F,
	.U             = 0x20,
	.Left_Bracket  = 0x21,
	.I             = 0x22,
	.P             = 0x23,
	.Enter         = 0x24,
	.L             = 0x25,
	.J             = 0x26,
	.Apostrophe    = 0x27,
	.K             = 0x28,
	.Semicolon     = 0x29,
	.Backslash     = 0x2A,
	.Comma         = 0x2B,
	.Slash         = 0x2C,
	.N             = 0x2D,
	.M             = 0x2E,
	.Period        = 0x2F,
	.Tab           = 0x30,
	.Space         = 0x31,
	.Grave         = 0x32,
	.Backspace     = 0x33, // kVK_Delete
	.Escape        = 0x35,
	.F17           = 0x40,
	.F18           = 0x4F,
	.F19           = 0x50,
	.F20           = 0x5A,
	.F5            = 0x60,
	.F6            = 0x61,
	.F7            = 0x62,
	.F3            = 0x63,
	.F8            = 0x64,
	.F9            = 0x65,
	.F11           = 0x67,
	.F13           = 0x69,
	.F16           = 0x6A,
	.F14           = 0x6B,
	.F10           = 0x6D,
	.F12           = 0x6F,
	.F15           = 0x71,
	.Insert        = 0x72, // kVK_Help, where Insert is on a PC keyboard
	.Home          = 0x73,
	.Page_Up       = 0x74,
	.Delete        = 0x75, // kVK_ForwardDelete
	.F4            = 0x76,
	.End           = 0x77,
	.F2            = 0x78,
	.Page_Down     = 0x79,
	.F1            = 0x7A,
	.Left          = 0x7B,
	.Right         = 0x7C,
	.Down          = 0x7D,
	.Up            = 0x7E,
	.F21           = NONE,
	.F22           = NONE,
	.F23           = NONE,
	.F24           = NONE,
	.Pause         = NONE,
	.Scroll_Lock   = NONE,
	.Print_Screen  = NONE,
}

@(private = "file")
MOD_CODES := [Mod][2]u16 {
	.Ctrl  = {0x3B, 0x3E},
	.Shift = {0x38, 0x3C},
	.Alt   = {0x3A, 0x3D}, // Option
	.Super = {0x37, 0x36}, // Command
}

Backend :: struct {
	allowed: bool,
}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	b.allowed = bool(CGPreflightListenEventAccess())
	if !b.allowed {
		// Shows macOS's own prompt, the first time.
		CGRequestListenEventAccess()
	}
	return describe(b)
}

backend_close :: proc(b: ^Backend) {}

@(private = "file")
down :: proc(code: u16) -> bool {
	return code != NONE && bool(CGEventSourceKeyState(.HID_System, code))
}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {
	for key in wanted {
		if down(KVK_CODES[key]) {
			s.keys += {key}
		}
	}
	for codes, mod in MOD_CODES {
		if down(codes[0]) || down(codes[1]) {
			s.mods += {mod}
		}
	}
}

// backend_status notices the permission being given while we run.
backend_status :: proc(b: ^Backend) -> (st: Status, message: string, changed: bool) {
	if b.allowed {
		return .Ok, "", false
	}
	b.allowed = bool(CGPreflightListenEventAccess())
	st, message = describe(b)
	return st, message, b.allowed
}

@(private = "file")
describe :: proc(b: ^Backend) -> (Status, string) {
	if b.allowed {
		return .Ok, "Watching the keyboard."
	}
	return .Limited, "Allow yap in System Settings > Privacy & Security > Input Monitoring."
}
