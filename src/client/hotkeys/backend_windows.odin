#+build windows
package hotkeys

import win "core:sys/windows"

/*
On Windows GetAsyncKeyState says whether a key is down right now,
whichever window has the focus. Its virtual keys follow the keyboard
layout for letters and a few symbols, where the other platforms go by a
key's position.

It sees nothing while a program running as administrator has the focus
(unless yap runs as administrator too), as with any other way of
watching the keyboard from an ordinary program.
*/

@(private = "file")
VK_CODES := [Key]i32 {
	.None          = 0,
	.A             = 'A',
	.B             = 'B',
	.C             = 'C',
	.D             = 'D',
	.E             = 'E',
	.F             = 'F',
	.G             = 'G',
	.H             = 'H',
	.I             = 'I',
	.J             = 'J',
	.K             = 'K',
	.L             = 'L',
	.M             = 'M',
	.N             = 'N',
	.O             = 'O',
	.P             = 'P',
	.Q             = 'Q',
	.R             = 'R',
	.S             = 'S',
	.T             = 'T',
	.U             = 'U',
	.V             = 'V',
	.W             = 'W',
	.X             = 'X',
	.Y             = 'Y',
	.Z             = 'Z',
	.Num_0         = '0',
	.Num_1         = '1',
	.Num_2         = '2',
	.Num_3         = '3',
	.Num_4         = '4',
	.Num_5         = '5',
	.Num_6         = '6',
	.Num_7         = '7',
	.Num_8         = '8',
	.Num_9         = '9',
	.F1            = win.VK_F1,
	.F2            = win.VK_F2,
	.F3            = win.VK_F3,
	.F4            = win.VK_F4,
	.F5            = win.VK_F5,
	.F6            = win.VK_F6,
	.F7            = win.VK_F7,
	.F8            = win.VK_F8,
	.F9            = win.VK_F9,
	.F10           = win.VK_F10,
	.F11           = win.VK_F11,
	.F12           = win.VK_F12,
	.F13           = win.VK_F13,
	.F14           = win.VK_F14,
	.F15           = win.VK_F15,
	.F16           = win.VK_F16,
	.F17           = win.VK_F17,
	.F18           = win.VK_F18,
	.F19           = win.VK_F19,
	.F20           = win.VK_F20,
	.F21           = win.VK_F21,
	.F22           = win.VK_F22,
	.F23           = win.VK_F23,
	.F24           = win.VK_F24,
	.Space         = win.VK_SPACE,
	.Enter         = win.VK_RETURN,
	.Tab           = win.VK_TAB,
	.Escape        = win.VK_ESCAPE,
	.Backspace     = win.VK_BACK,
	.Insert        = win.VK_INSERT,
	.Delete        = win.VK_DELETE,
	.Home          = win.VK_HOME,
	.End           = win.VK_END,
	.Page_Up       = win.VK_PRIOR,
	.Page_Down     = win.VK_NEXT,
	.Up            = win.VK_UP,
	.Down          = win.VK_DOWN,
	.Left          = win.VK_LEFT,
	.Right         = win.VK_RIGHT,
	.Minus         = win.VK_OEM_MINUS,
	.Equal         = win.VK_OEM_PLUS,
	.Left_Bracket  = win.VK_OEM_4,
	.Right_Bracket = win.VK_OEM_6,
	.Backslash     = win.VK_OEM_5,
	.Semicolon     = win.VK_OEM_1,
	.Apostrophe    = win.VK_OEM_7,
	.Grave         = win.VK_OEM_3,
	.Comma         = win.VK_OEM_COMMA,
	.Period        = win.VK_OEM_PERIOD,
	.Slash         = win.VK_OEM_2,
	.Pause         = win.VK_PAUSE,
	.Scroll_Lock   = win.VK_SCROLL,
	.Print_Screen  = win.VK_SNAPSHOT,
}

// Either side of each; there's no plain VK for the Windows key.
@(private = "file")
MOD_CODES := [Mod][2]i32 {
	.Ctrl  = {win.VK_CONTROL, win.VK_CONTROL},
	.Shift = {win.VK_SHIFT, win.VK_SHIFT},
	.Alt   = {win.VK_MENU, win.VK_MENU},
	.Super = {win.VK_LWIN, win.VK_RWIN},
}

Backend :: struct {}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	return .Ok, "Watching the keyboard."
}

backend_close :: proc(b: ^Backend) {}

@(private = "file")
down :: proc(vk: i32) -> bool {
	// The high bit: down now. (The low one, "pressed since last asked",
	// is shared with every other program asking, so it's no use.)
	return u16(win.GetAsyncKeyState(vk)) & 0x8000 != 0
}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {
	for key in wanted {
		if down(VK_CODES[key]) {
			s.keys += {key}
		}
	}
	for codes, mod in MOD_CODES {
		if down(codes[0]) || down(codes[1]) {
			s.mods += {mod}
		}
	}
}

backend_status :: proc(b: ^Backend) -> (Status, string, bool) {
	return .Ok, "", false
}
