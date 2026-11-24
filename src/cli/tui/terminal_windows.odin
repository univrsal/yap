#+build windows
package tui

import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import "core:unicode/utf16"
import "core:unicode/utf8"

// The Windows console. With virtual-terminal processing on, the console takes
// the same escape sequences as a Unix terminal, and with virtual-terminal input
// it sends keys, the mouse and pastes as the same sequences, so input.odin and
// flush.odin work unchanged. What differs is getting at them: the input comes as
// console records (read with ReadConsoleInputW and turned back into UTF-8 here),
// a resize is one of those records instead of a signal, and the wait is on the
// console handle and an event instead of poll and a pipe.
//
// Needs Windows 10 1809 or later (or Windows Terminal), which have the
// virtual-terminal modes.

@(private = "file")
ENABLE_EXTENDED_FLAGS :: win.DWORD(0x0080)

// The mouse buttons as the console reports them.
@(private = "file")
FROM_LEFT_1ST_BUTTON_PRESSED :: 0x1
@(private = "file")
RIGHTMOST_BUTTON_PRESSED :: 0x2
@(private = "file")
FROM_LEFT_2ND_BUTTON_PRESSED :: 0x4
@(private = "file")
MOUSE_MOVED :: 0x1
@(private = "file")
MOUSE_WHEELED :: 0x4

// The console while the program has it: raw, on its own screen, reporting the
// mouse and pastes. Restored by terminal_close.
Terminal :: struct {
	saved_in_mode:  win.DWORD,
	saved_out_mode: win.DWORD,
	saved_in_cp:    win.CODEPAGE,
	saved_out_cp:   win.CODEPAGE,
	is_raw:         bool,
}

@(private = "file")
h_in: win.HANDLE
@(private = "file")
h_out: win.HANDLE
// The event terminal_wake sets, from any thread or the console's control handler.
@(private = "file")
wake_event: win.HANDLE
@(private = "file")
resized: bool
// What was read from the console and not yet given to terminal_read, as UTF-8.
// Only the main thread touches it.
@(private = "file")
pending: [dynamic]u8
// The first half of a character outside the BMP, until the second comes.
@(private = "file")
high_surrogate: u16
// The mouse buttons held at the last mouse record, for turning the records into
// presses and releases.
@(private = "file")
mouse_buttons: win.DWORD
// The console can't be read any more: terminal_read gives 0.
@(private = "file")
gone: bool

// terminal_open puts the console in raw mode and on its own screen. It fails if
// stdin or stdout is not a console, or the console is too old for escape
// sequences.
terminal_open :: proc(t: ^Terminal) -> bool {
	h_in = win.GetStdHandle(win.STD_INPUT_HANDLE)
	h_out = win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if !bool(win.GetConsoleMode(h_in, &t.saved_in_mode)) ||
	   !bool(win.GetConsoleMode(h_out, &t.saved_out_mode)) {
		return false
	}
	out_mode := t.saved_out_mode | win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING
	if !bool(win.SetConsoleMode(h_out, out_mode | win.DISABLE_NEWLINE_AUTO_RETURN)) &&
	   !bool(win.SetConsoleMode(h_out, out_mode)) {
		return false
	}
	// No line editing, echo or Ctrl+C handling (it arrives as the byte 3, as
	// on Unix), and no Quick Edit, which would take the mouse for selecting.
	in_mode :=
		ENABLE_EXTENDED_FLAGS |
		win.ENABLE_WINDOW_INPUT |
		win.ENABLE_MOUSE_INPUT |
		win.ENABLE_VIRTUAL_TERMINAL_INPUT
	if !bool(win.SetConsoleMode(h_in, in_mode)) {
		win.SetConsoleMode(h_out, t.saved_out_mode)
		return false
	}
	t.saved_in_cp = win.GetConsoleCP()
	t.saved_out_cp = win.GetConsoleOutputCP()
	win.SetConsoleCP(.UTF8)
	win.SetConsoleOutputCP(.UTF8)
	t.is_raw = true

	ev := win.CreateEventW(nil, false, false, nil)
	if ev == nil {
		terminal_close(t)
		return false
	}
	sync.atomic_store(&wake_event, ev)
	gone = false
	high_surrogate = 0
	mouse_buttons = 0
	clear(&pending)

	terminal_write(SEQ_ENTER)
	return true
}

// terminal_close gives the console back as it was. Safe to call twice.
terminal_close :: proc(t: ^Terminal) {
	if !t.is_raw {
		return
	}
	terminal_write(SEQ_LEAVE)
	win.SetConsoleMode(h_in, t.saved_in_mode)
	win.SetConsoleMode(h_out, t.saved_out_mode)
	win.SetConsoleCP(t.saved_in_cp)
	win.SetConsoleOutputCP(t.saved_out_cp)
	t.is_raw = false
	if ev := sync.atomic_exchange(&wake_event, nil); ev != nil {
		win.CloseHandle(ev)
	}
	delete(pending)
	pending = nil
}

// terminal_wake makes terminal_wait return, from any thread.
terminal_wake :: proc "c" () {
	if ev := sync.atomic_load(&wake_event); ev != nil {
		win.SetEvent(ev)
	}
}

// terminal_size is the screen's width and height in cells: the visible window,
// not the console's whole buffer.
terminal_size :: proc() -> (w, h: int) {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if !bool(win.GetConsoleScreenBufferInfo(h_out, &info)) {
		return 80, 24
	}
	w = int(info.srWindow.Right) - int(info.srWindow.Left) + 1
	h = int(info.srWindow.Bottom) - int(info.srWindow.Top) + 1
	if w <= 0 || h <= 0 {
		return 80, 24
	}
	return
}

// terminal_take_resized says whether the window changed size since the last call.
terminal_take_resized :: proc() -> bool {
	return sync.atomic_exchange(&resized, false)
}

// terminal_wait waits up to `timeout_ms` (-1 for ever) for input or a wake-up.
// The console handle is also signalled for records that are no input here (a key
// let go, the focus), so it waits again until there is something to read.
terminal_wait :: proc(t: ^Terminal, timeout_ms: int) -> (res: Wait_Result) {
	if len(pending) > 0 || gone {
		res.input = true
		return
	}
	start := time.tick_now()
	handles := [2]win.HANDLE{h_in, sync.atomic_load(&wake_event)}
	for {
		ms := win.INFINITE
		if timeout_ms >= 0 {
			spent := int(time.duration_milliseconds(time.tick_since(start)))
			if spent >= timeout_ms && spent > 0 {
				return
			}
			ms = win.DWORD(max(timeout_ms - spent, 0))
		}
		switch win.WaitForMultipleObjects(2, &handles[0], false, ms) {
		case win.WAIT_OBJECT_0:
			was_resized := sync.atomic_load(&resized)
			read_records()
			if len(pending) > 0 || gone {
				res.input = true
				return
			}
			if !was_resized && sync.atomic_load(&resized) {
				res.woken = true // to be drawn again at the new size
				return
			}
		case win.WAIT_OBJECT_0 + 1:
			res.woken = true
			return
		case:
			return // timed out
		}
		if timeout_ms == 0 {
			return
		}
	}
}

// terminal_read gives what the console has sent, up to len(buf) bytes. 0 means
// the console is gone.
terminal_read :: proc(buf: []u8) -> int {
	n := copy(buf, pending[:])
	remove_range(&pending, 0, n)
	return n
}

// terminal_write writes everything. It goes as UTF-16, which every console
// takes, whatever its code page and font.
terminal_write :: proc(s: string) {
	if len(s) == 0 {
		return
	}
	wide := make([]u16, len(s), context.temp_allocator)
	n := utf16.encode_string(wide, s)
	data := wide[:n]
	for len(data) > 0 {
		written: win.DWORD
		if !bool(win.WriteConsoleW(h_out, raw_data(data), win.DWORD(len(data)), &written, nil)) ||
		   written == 0 {
			return
		}
		data = data[written:]
	}
}

// read_records takes the records the console has and adds their text to pending.
@(private = "file")
read_records :: proc() {
	records: [128]win.INPUT_RECORD
	count: win.DWORD
	if !bool(win.GetNumberOfConsoleInputEvents(h_in, &count)) {
		gone = true
		return
	}
	if count == 0 {
		return
	}
	got: win.DWORD
	if !bool(win.ReadConsoleInputW(h_in, &records[0], min(count, len(records)), &got)) {
		gone = true
		return
	}
	window_top := -1
	for &r in records[:got] {
		#partial switch r.EventType {
		case .KEY_EVENT:
			key := r.Event.KeyEvent
			c := u16(key.uChar.UnicodeChar)
			if !bool(key.bKeyDown) || c == 0 {
				continue
			}
			for _ in 0 ..< max(int(key.wRepeatCount), 1) {
				add_utf16(c)
			}
		case .MOUSE_EVENT:
			// With virtual-terminal input the console sends the mouse as escape
			// sequences already; the older conhost sends records, which are made
			// into the same sequences.
			if window_top < 0 {
				info: win.CONSOLE_SCREEN_BUFFER_INFO
				window_top = 0
				if win.GetConsoleScreenBufferInfo(h_out, &info) {
					window_top = int(info.srWindow.Top)
				}
			}
			add_mouse(r.Event.MouseEvent, window_top)
		case .WINDOW_BUFFER_SIZE_EVENT:
			sync.atomic_store(&resized, true)
		}
	}
}

@(private = "file")
add_utf16 :: proc(c: u16) {
	r: rune
	switch {
	case c >= 0xd800 && c < 0xdc00:
		high_surrogate = c
		return
	case c >= 0xdc00 && c < 0xe000:
		if high_surrogate == 0 {
			return
		}
		r = utf16.decode_surrogate_pair(rune(high_surrogate), rune(c))
		high_surrogate = 0
	case:
		r = rune(c)
	}
	bytes, n := utf8.encode_rune(r)
	append(&pending, ..bytes[:n])
}

// add_mouse writes a mouse record as the SGR report a terminal would send for it
// (the buttons and dragging, as asked for with ?1002h).
@(private = "file")
add_mouse :: proc(m: win.MOUSE_EVENT_RECORD, window_top: int) {
	x := int(m.dwMousePosition.X) + 1
	y := int(m.dwMousePosition.Y) - window_top + 1
	mods := 0
	if m.dwControlKeyState & 0x10 != 0 {mods |= 4} 	// SHIFT_PRESSED
	if m.dwControlKeyState & 0x3 != 0 {mods |= 8} 	// either Alt
	if m.dwControlKeyState & 0xc != 0 {mods |= 16} 	// either Ctrl

	if m.dwEventFlags & MOUSE_WHEELED != 0 {
		// The high word is how far, positive away from the user.
		up := i16(m.dwButtonState >> 16) > 0
		add_sgr(64 + (0 if up else 1) + mods, x, y, false)
		return
	}
	BUTTONS :: [3]struct {
		mask: win.DWORD,
		code: int,
	} {
		{FROM_LEFT_1ST_BUTTON_PRESSED, 0},
		{FROM_LEFT_2ND_BUTTON_PRESSED, 1},
		{RIGHTMOST_BUTTON_PRESSED, 2},
	}
	now := m.dwButtonState & 0x7
	changed := false
	for b in BUTTONS {
		was, is := mouse_buttons & b.mask != 0, now & b.mask != 0
		if was != is {
			add_sgr(b.code + mods, x, y, !is)
			changed = true
		}
	}
	mouse_buttons = now
	if !changed && m.dwEventFlags & MOUSE_MOVED != 0 && now != 0 {
		for b in BUTTONS {
			if now & b.mask != 0 {
				add_sgr(32 + b.code + mods, x, y, false)
				break
			}
		}
	}
}

@(private = "file")
add_sgr :: proc(b, x, y: int, release: bool) {
	buf: [32]u8
	s := fmt.bprintf(buf[:], "\x1b[<%d;%d;%d%c", b, x, y, 'm' if release else 'M')
	append(&pending, ..transmute([]u8)s)
}

// terminal_copy puts text on the system's clipboard, which the console can't be
// asked to do (the old console has no OSC 52). False if it could not.
terminal_copy :: proc(text: string) -> bool {
	opened := false
	for _ in 0 ..< 10 {
		// Another program may have the clipboard open for a moment.
		if win.OpenClipboard(nil) {
			opened = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	if !opened {
		return false
	}
	defer win.CloseClipboard()
	wide := make([]u16, len(text) + 1, context.temp_allocator)
	n := utf16.encode_string(wide, text)
	mem := win.GlobalAlloc(win.GMEM_MOVEABLE, uint((n + 1) * size_of(u16)))
	if mem == nil {
		return false
	}
	p := ([^]u16)(win.GlobalLock(win.HGLOBAL(mem)))
	if p == nil {
		win.GlobalFree(win.HGLOBAL(mem))
		return false
	}
	copy(p[:n], wide[:n])
	p[n] = 0
	win.GlobalUnlock(win.HGLOBAL(mem))
	CF_UNICODETEXT :: 13
	win.EmptyClipboard()
	if win.SetClipboardData(CF_UNICODETEXT, win.HANDLE(mem)) == nil {
		win.GlobalFree(win.HGLOBAL(mem))
		return false
	}
	return true
}
