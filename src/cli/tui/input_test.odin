package tui

import "core:testing"

@(private = "file")
decode_all :: proc(chunks: ..string) -> [dynamic]Event {
	d: Decoder
	defer decoder_destroy(&d)
	events: [dynamic]Event
	for c in chunks {
		decoder_feed(&d, transmute([]u8)c, &events)
	}
	return events
}

@(private = "file")
free_events :: proc(events: [dynamic]Event) {
	for e in events {
		if p, ok := e.(Paste_Event); ok {
			delete(p.text)
		}
	}
	delete(events)
}

@(private = "file")
key :: proc(k: Key, mods := Mods{}) -> Event {
	return Key_Event{key = k, mods = mods}
}

@(private = "file")
rn :: proc(r: rune, mods := Mods{}) -> Event {
	return Key_Event{key = .Rune, rune = r, mods = mods}
}

@(test)
test_plain_keys :: proc(t: ^testing.T) {
	ev := decode_all("ab é日\r\t\x7f")
	defer free_events(ev)
	want := [?]Event {
		rn('a'),
		rn('b'),
		rn(' '),
		rn('é'),
		rn('日'),
		key(.Enter),
		key(.Tab),
		key(.Backspace),
	}
	testing.expect_value(t, len(ev), len(want))
	for w, i in want {
		testing.expect_value(t, ev[i], w)
	}
}

@(test)
test_control_keys :: proc(t: ^testing.T) {
	ev := decode_all("\x01\x0b\x17")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 3)
	testing.expect_value(t, ev[0], rn('a', {.Ctrl}))
	testing.expect_value(t, ev[1], rn('k', {.Ctrl}))
	testing.expect_value(t, ev[2], rn('w', {.Ctrl}))
}

@(test)
test_arrows_and_friends :: proc(t: ^testing.T) {
	ev := decode_all(
		"\x1b[A\x1b[B\x1b[C\x1b[D\x1b[H\x1b[F\x1b[5~\x1b[6~\x1b[3~\x1b[2~\x1b[15~\x1b[24~\x1bOP\x1b[Z",
	)
	defer free_events(ev)
	want := [?]Event {
		key(.Up),
		key(.Down),
		key(.Right),
		key(.Left),
		key(.Home),
		key(.End),
		key(.Page_Up),
		key(.Page_Down),
		key(.Delete),
		key(.Insert),
		key(.F5),
		key(.F12),
		key(.F1),
		key(.Tab, {.Shift}),
	}
	testing.expect_value(t, len(ev), len(want))
	for w, i in want {
		testing.expect_value(t, ev[i], w)
	}
}

@(test)
test_modified_keys :: proc(t: ^testing.T) {
	ev := decode_all("\x1b[1;5C\x1b[1;3D\x1b[1;2A\x1b[3;5~\x1bx\x1b\r")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 6)
	testing.expect_value(t, ev[0], key(.Right, {.Ctrl}))
	testing.expect_value(t, ev[1], key(.Left, {.Alt}))
	testing.expect_value(t, ev[2], key(.Up, {.Shift}))
	testing.expect_value(t, ev[3], key(.Delete, {.Ctrl}))
	testing.expect_value(t, ev[4], rn('x', {.Alt}))
	testing.expect_value(t, ev[5], key(.Enter, {.Alt}))
}

@(test)
test_escape_alone_needs_a_timeout :: proc(t: ^testing.T) {
	d: Decoder
	defer decoder_destroy(&d)
	events: [dynamic]Event
	defer free_events(events)
	decoder_feed(&d, {0x1b}, &events)
	testing.expect_value(t, len(events), 0)
	decoder_timeout(&d, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], key(.Escape))
	// If more arrives, it is a sequence after all.
	clear(&events)
	decoder_feed(&d, {0x1b}, &events)
	decoder_feed(&d, {'[', 'A'}, &events)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0], key(.Up))
}

@(test)
test_sequences_split_across_reads :: proc(t: ^testing.T) {
	ev := decode_all("\x1b", "[", "1;5", "C", "\xe6", "\x97", "\xa5")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 2)
	testing.expect_value(t, ev[0], key(.Right, {.Ctrl}))
	testing.expect_value(t, ev[1], rn('日'))
}

@(test)
test_garbage_is_skipped :: proc(t: ^testing.T) {
	// An invalid UTF-8 byte, an unknown sequence (focus in), then a key.
	ev := decode_all("\xff\x1b[I\x1b[99~a")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 1)
	testing.expect_value(t, ev[0], rn('a'))
}

@(test)
test_mouse :: proc(t: ^testing.T) {
	ev := decode_all(
		"\x1b[<0;10;5M", // left press at column 10, row 5
		"\x1b[<0;10;5m", // release
		"\x1b[<2;1;1M", // right press
		"\x1b[<32;11;5M", // drag
		"\x1b[<35;12;6M", // move with no button
		"\x1b[<64;3;4M", // wheel up
		"\x1b[<65;3;4M", // wheel down
		"\x1b[<16;3;4M", // ctrl + left
	)
	defer free_events(ev)
	testing.expect_value(t, len(ev), 8)
	testing.expect_value(t, ev[0], Mouse_Event{.Press, .Left, 9, 4, {}})
	testing.expect_value(t, ev[1], Mouse_Event{.Release, .Left, 9, 4, {}})
	testing.expect_value(t, ev[2], Mouse_Event{.Press, .Right, 0, 0, {}})
	testing.expect_value(t, ev[3], Mouse_Event{.Drag, .Left, 10, 4, {}})
	testing.expect_value(t, ev[4], Mouse_Event{.Move, .None, 11, 5, {}})
	testing.expect_value(t, ev[5], Mouse_Event{kind = .Wheel_Up, x = 2, y = 3})
	testing.expect_value(t, ev[6], Mouse_Event{kind = .Wheel_Down, x = 2, y = 3})
	testing.expect_value(t, ev[7], Mouse_Event{.Press, .Left, 2, 3, {.Ctrl}})
}

@(test)
test_bracketed_paste :: proc(t: ^testing.T) {
	ev := decode_all("a\x1b[200~line one\nline two\x1b[201~b")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 3)
	testing.expect_value(t, ev[0], rn('a'))
	if p, ok := ev[1].(Paste_Event); ok {
		testing.expect_value(t, p.text, "line one\nline two")
	} else {
		testing.fail_now(t, "no paste")
	}
	testing.expect_value(t, ev[2], rn('b'))
}

@(test)
test_paste_in_pieces_and_with_escapes_inside :: proc(t: ^testing.T) {
	// The end mark split over two reads, and a stray escape sequence inside.
	ev := decode_all("\x1b[200~ab\x1b[A cd\x1b[2", "01~x")
	defer free_events(ev)
	testing.expect_value(t, len(ev), 2)
	if p, ok := ev[0].(Paste_Event); ok {
		testing.expect_value(t, p.text, "ab\x1b[A cd")
	} else {
		testing.fail_now(t, "no paste")
	}
	testing.expect_value(t, ev[1], rn('x'))
}
