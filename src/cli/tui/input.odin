package tui

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Turns the bytes a terminal sends into events. The terminal sends keys as
// plain bytes or escape sequences, mouse reports as SGR sequences once asked
// for (`?1006h`), and a paste between two marks once bracketed paste is on
// (`?2004h`).

Mod :: enum u8 {
	Shift,
	Alt,
	Ctrl,
}

Mods :: bit_set[Mod;u8]

Key :: enum u8 {
	Rune, // a character: see Key_Event.r
	Enter,
	Tab,
	Backspace,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Delete,
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
}

// A key was pressed. With Ctrl, `rune` is the letter without the control (so
// Ctrl+A is 'a').
Key_Event :: struct {
	key:  Key,
	rune: rune, // for .Rune
	mods: Mods,
}

Mouse_Button :: enum u8 {
	None,
	Left,
	Middle,
	Right,
}

Mouse_Kind :: enum u8 {
	Press,
	Release,
	Drag, // moved with a button held
	Move, // moved with none
	Wheel_Up,
	Wheel_Down,
}

// x and y count from 0 at the top left.
Mouse_Event :: struct {
	kind:   Mouse_Kind,
	button: Mouse_Button,
	x, y:   int,
	mods:   Mods,
}

// Text pasted into the terminal (bracketed paste), as sent. Owned by the receiver.
Paste_Event :: struct {
	text: string,
}

Event :: union {
	Key_Event,
	Mouse_Event,
	Paste_Event,
}

Decoder :: struct {
	buf:      [dynamic]u8, // bytes that don't make an event yet
	in_paste: bool,
	paste:    [dynamic]u8,
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.buf)
	delete(d.paste)
	d^ = {}
}

PASTE_START :: "\x1b[200~"
PASTE_END :: "\x1b[201~"

// decoder_feed adds bytes the terminal sent and appends the events they make to
// `events`. An incomplete sequence at the end waits for the next call; a lone
// Escape is also such a sequence, since it could begin one, so call
// decoder_timeout when no more bytes come soon.
decoder_feed :: proc(d: ^Decoder, bytes: []u8, events: ^[dynamic]Event) {
	append(&d.buf, ..bytes)
	for len(d.buf) > 0 {
		if d.in_paste {
			if !decode_paste(d, events) {
				return
			}
			continue
		}
		n, ev, status := decode_one(d.buf[:])
		switch status {
		case .Need_More:
			return
		case .Skip:
			remove_front(&d.buf, n)
		case .Event:
			remove_front(&d.buf, n)
			if k, is_key := ev.(Key_Event); is_key && k.key == .Rune && k.rune == PASTE_MARK {
				d.in_paste = true
				continue
			}
			append(events, ev)
		}
	}
}

// decoder_timeout is called when the terminal sent nothing for a moment: what is
// waiting is complete as it is, so a lone Escape is the Escape key.
decoder_timeout :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	if len(d.buf) == 1 && d.buf[0] == 0x1b {
		clear(&d.buf)
		append(events, Key_Event{key = .Escape})
	} else if len(d.buf) > 0 && !d.in_paste {
		// An unfinished sequence that isn't going to be finished: drop it.
		clear(&d.buf)
	}
}

// Stands in for the paste start in decode_one's result.
@(private = "file")
PASTE_MARK :: rune(-2)

@(private = "file")
decode_paste :: proc(d: ^Decoder, events: ^[dynamic]Event) -> bool {
	s := string(d.buf[:])
	if i := strings.index(s, PASTE_END); i >= 0 {
		append(&d.paste, ..d.buf[:i])
		remove_front(&d.buf, i + len(PASTE_END))
		text := strings.clone(string(d.paste[:]))
		clear(&d.paste)
		d.in_paste = false
		append(events, Paste_Event{text})
		return true
	}
	// Keep a possible start of the end mark, take the rest.
	keep := 0
	for k := min(len(PASTE_END) - 1, len(s)); k > 0; k -= 1 {
		if strings.has_prefix(PASTE_END, s[len(s) - k:]) {
			keep = k
			break
		}
	}
	append(&d.paste, ..d.buf[:len(d.buf) - keep])
	remove_front(&d.buf, len(d.buf) - keep)
	return false
}

@(private = "file")
remove_front :: proc(b: ^[dynamic]u8, n: int) {
	copy(b[:], b[n:])
	resize(b, len(b) - n)
}

@(private = "file")
Status :: enum {
	Event,
	Skip, // bytes that mean nothing
	Need_More,
}

@(private = "file")
decode_one :: proc(b: []u8) -> (n: int, ev: Event, status: Status) {
	c := b[0]
	switch {
	case c == 0x1b:
		return decode_escape(b)
	case c == '\r' || c == '\n':
		return 1, Key_Event{key = .Enter}, .Event
	case c == '\t':
		return 1, Key_Event{key = .Tab}, .Event
	case c == 0x7f || c == 0x08:
		return 1, Key_Event{key = .Backspace}, .Event
	case c == 0:
		return 1, Key_Event{key = .Rune, rune = ' ', mods = {.Ctrl}}, .Event // Ctrl+Space
	case c < 0x20:
		return 1, Key_Event{key = .Rune, rune = rune('a' + c - 1), mods = {.Ctrl}}, .Event
	case c < 0x80:
		return 1, Key_Event{key = .Rune, rune = rune(c)}, .Event
	}
	// UTF-8
	if !utf8.full_rune(b) {
		return 0, nil, .Need_More
	}
	r, size := utf8.decode_rune(b)
	if r == utf8.RUNE_ERROR && size <= 1 {
		return 1, nil, .Skip
	}
	return size, Key_Event{key = .Rune, rune = r}, .Event
}

@(private = "file")
decode_escape :: proc(b: []u8) -> (n: int, ev: Event, status: Status) {
	if len(b) == 1 {
		return 0, nil, .Need_More
	}
	switch b[1] {
	case '[':
		return decode_csi(b)
	case 'O':
		// SS3: F1 to F4 and, in application mode, the arrows
		if len(b) < 3 {
			return 0, nil, .Need_More
		}
		key: Key
		switch b[2] {
		case 'P': key = .F1
		case 'Q': key = .F2
		case 'R': key = .F3
		case 'S': key = .F4
		case 'A': key = .Up
		case 'B': key = .Down
		case 'C': key = .Right
		case 'D': key = .Left
		case 'H': key = .Home
		case 'F': key = .End
		case:
			return 3, nil, .Skip
		}
		return 3, Key_Event{key = key}, .Event
	case 0x1b:
		// Escape pressed twice, or Alt+Escape: take the first one alone.
		return 1, Key_Event{key = .Escape}, .Event
	}
	// Alt and a key: the escape is followed by what the key alone would send.
	n2, ev2, st := decode_one(b[1:])
	if st != .Event {
		return n2 + 1 if st == .Skip else 0, nil, st
	}
	if k, ok := ev2.(Key_Event); ok {
		k.mods += {.Alt}
		return n2 + 1, k, .Event
	}
	return n2 + 1, nil, .Skip
}

@(private = "file")
decode_csi :: proc(b: []u8) -> (n: int, ev: Event, status: Status) {
	// ESC [ params final: params are 0x30-0x3f, intermediates 0x20-0x2f, final 0x40-0x7e.
	i := 2
	for i < len(b) && b[i] >= 0x20 && b[i] < 0x40 {
		i += 1
	}
	if i >= len(b) {
		return 0, nil, .Need_More
	}
	final := b[i]
	params := string(b[2:i])
	n = i + 1
	if final < 0x40 || final > 0x7e {
		return n, nil, .Skip
	}

	if len(params) > 0 && params[0] == '<' && (final == 'M' || final == 'm') {
		return n, decode_mouse(params[1:], final == 'm'), .Event
	}
	if final == '~' && params == "200" {
		return n, Key_Event{key = .Rune, rune = PASTE_MARK}, .Event
	}

	nums: [4]int
	count := 0
	for part in strings.split_iterator(&params, ";") {
		if count < len(nums) {
			nums[count], _ = strconv.parse_int(part)
			count += 1
		}
	}
	mods := csi_mods(nums[1]) if count > 1 else Mods{}

	key: Key
	switch final {
	case 'A': key = .Up
	case 'B': key = .Down
	case 'C': key = .Right
	case 'D': key = .Left
	case 'H': key = .Home
	case 'F': key = .End
	case 'P': key = .F1
	case 'Q': key = .F2
	case 'R': key = .F3
	case 'S': key = .F4
	case 'Z':
		return n, Key_Event{key = .Tab, mods = {.Shift}}, .Event
	case '~':
		switch nums[0] {
		case 1, 7: key = .Home
		case 2: key = .Insert
		case 3: key = .Delete
		case 4, 8: key = .End
		case 5: key = .Page_Up
		case 6: key = .Page_Down
		case 15: key = .F5
		case 17: key = .F6
		case 18: key = .F7
		case 19: key = .F8
		case 20: key = .F9
		case 21: key = .F10
		case 23: key = .F11
		case 24: key = .F12
		case:
			return n, nil, .Skip
		}
	case:
		return n, nil, .Skip // focus in and out, cursor reports, ...
	}
	return n, Key_Event{key = key, mods = mods}, .Event
}

// The modifier parameter of a key is 1 + a bit set: 1 shift, 2 alt, 4 ctrl.
@(private = "file")
csi_mods :: proc(param: int) -> (m: Mods) {
	bits := param - 1
	if bits < 0 {
		return
	}
	if bits & 1 != 0 {m += {.Shift}}
	if bits & 2 != 0 {m += {.Alt}}
	if bits & 4 != 0 {m += {.Ctrl}}
	return
}

// decode_mouse reads "b;x;y" of an SGR report; `release` is the lower case m.
@(private = "file")
decode_mouse :: proc(params: string, release: bool) -> Event {
	params := params
	nums: [3]int
	i := 0
	for part in strings.split_iterator(&params, ";") {
		if i < 3 {
			nums[i], _ = strconv.parse_int(part)
			i += 1
		}
	}
	b, x, y := nums[0], nums[1] - 1, nums[2] - 1
	ev := Mouse_Event {
		x = x,
		y = y,
	}
	if b & 4 != 0 {ev.mods += {.Shift}}
	if b & 8 != 0 {ev.mods += {.Alt}}
	if b & 16 != 0 {ev.mods += {.Ctrl}}
	motion := b & 32 != 0
	switch {
	case b & 64 != 0:
		ev.kind = .Wheel_Down if b & 1 != 0 else .Wheel_Up
	case:
		switch b & 3 {
		case 0: ev.button = .Left
		case 1: ev.button = .Middle
		case 2: ev.button = .Right
		case 3: ev.button = .None // motion with no button held
		}
		switch {
		case release: ev.kind = .Release
		case motion && ev.button == .None: ev.kind = .Move
		case motion: ev.kind = .Drag
		case: ev.kind = .Press
		}
	}
	return ev
}
