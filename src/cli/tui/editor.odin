package tui

import "core:strings"
import "core:unicode/utf8"

// A text field: what the message is typed in. Single or multi-line text with a
// cursor, the usual emacs keys, and a history of what was sent.
//
// The text is kept as UTF-8 and the cursor is a byte offset that is always at a
// rune's start.

HISTORY_MAX :: 100

Editor :: struct {
	text:    [dynamic]u8,
	cursor:  int,
	// Sent texts, oldest first. Browsing starts at `len(history)` (the text
	// being written, kept in `draft` while an old one is shown).
	history: [dynamic]string,
	browse:  int,
	draft:   string,
}

editor_destroy :: proc(e: ^Editor) {
	delete(e.text)
	for h in e.history {
		delete(h)
	}
	delete(e.history)
	delete(e.draft)
	e^ = {}
}

editor_text :: proc(e: ^Editor) -> string {
	return string(e.text[:])
}

// editor_set replaces the text and puts the cursor at its end.
editor_set :: proc(e: ^Editor, s: string) {
	clear(&e.text)
	append(&e.text, s)
	e.cursor = len(e.text)
	editor_stop_browsing(e)
}

editor_clear :: proc(e: ^Editor) {
	clear(&e.text)
	e.cursor = 0
	editor_stop_browsing(e)
}

@(private = "file")
editor_stop_browsing :: proc(e: ^Editor) {
	e.browse = len(e.history)
	delete(e.draft)
	e.draft = ""
}

// editor_insert inserts text at the cursor.
editor_insert :: proc(e: ^Editor, s: string) {
	inject_at(&e.text, e.cursor, ..transmute([]u8)s)
	e.cursor += len(s)
	e.browse = len(e.history)
}

// editor_remember adds the text to the history, as sent, and clears the field.
editor_remember :: proc(e: ^Editor) {
	text := editor_text(e)
	if text != "" && (len(e.history) == 0 || e.history[len(e.history) - 1] != text) {
		append(&e.history, strings.clone(text))
		if len(e.history) > HISTORY_MAX {
			delete(e.history[0])
			ordered_remove(&e.history, 0)
		}
	}
	editor_clear(e)
}

// editor_key handles a key and says whether the field used it. Enter is not
// used (it sends), except with Alt, which starts a new line.
editor_key :: proc(e: ^Editor, k: Key_Event) -> bool {
	ctrl, alt := .Ctrl in k.mods, .Alt in k.mods
	switch k.key {
	case .Rune:
		switch {
		case ctrl && !alt:
			return editor_ctrl(e, k.rune)
		case alt && !ctrl:
			switch k.rune {
			case 'b': e.cursor = word_start_before(e, e.cursor)
			case 'f': e.cursor = word_end_after(e, e.cursor)
			case 'd': delete_range(e, e.cursor, word_end_after(e, e.cursor))
			case: return false
			}
			return true
		case ctrl || alt:
			return false
		}
		buf, n := utf8.encode_rune(k.rune)
		editor_insert(e, string(buf[:n]))
	case .Enter:
		if .Alt in k.mods || .Shift in k.mods {
			editor_insert(e, "\n")
			return true
		}
		return false
	case .Backspace:
		switch {
		case alt: delete_range(e, word_start_before(e, e.cursor), e.cursor)
		case ctrl: delete_range(e, word_start_before(e, e.cursor), e.cursor)
		case: delete_range(e, rune_before(e, e.cursor), e.cursor)
		}
	case .Delete:
		delete_range(e, e.cursor, rune_after(e, e.cursor))
	case .Left:
		e.cursor = word_start_before(e, e.cursor) if ctrl || alt else rune_before(e, e.cursor)
	case .Right:
		e.cursor = word_end_after(e, e.cursor) if ctrl || alt else rune_after(e, e.cursor)
	case .Home:
		e.cursor = line_start(e, e.cursor)
	case .End:
		e.cursor = line_end(e, e.cursor)
	case .Up:
		return move_line(e, -1)
	case .Down:
		return move_line(e, 1)
	case .Tab, .Escape, .Insert, .Page_Up, .Page_Down, .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
		return false
	}
	return true
}

@(private = "file")
editor_ctrl :: proc(e: ^Editor, r: rune) -> bool {
	switch r {
	case 'a': e.cursor = line_start(e, e.cursor)
	case 'e': e.cursor = line_end(e, e.cursor)
	case 'b': e.cursor = rune_before(e, e.cursor)
	case 'f': e.cursor = rune_after(e, e.cursor)
	case 'd': delete_range(e, e.cursor, rune_after(e, e.cursor))
	case 'h': delete_range(e, rune_before(e, e.cursor), e.cursor)
	case 'w': delete_range(e, word_start_before(e, e.cursor), e.cursor)
	case 'u': delete_range(e, line_start(e, e.cursor), e.cursor)
	case 'k': delete_range(e, e.cursor, line_end(e, e.cursor))
	case: return false
	}
	return true
}

// move_line moves to the line above or below (lines are those the text is
// broken into by newlines). On the first line, up shows the sent text before;
// on the last, down the one after (and at the end of the history, the text
// that was being written).
@(private = "file")
move_line :: proc(e: ^Editor, dir: int) -> bool {
	text := editor_text(e)
	start := line_start(e, e.cursor)
	if dir < 0 && start == 0 {
		return history_step(e, -1)
	}
	if dir > 0 && line_end(e, e.cursor) == len(text) {
		return history_step(e, 1)
	}
	col := string_width(text[start:e.cursor])
	other: int // the start of the line to move to
	if dir < 0 {
		other = line_start(e, start - 1)
	} else {
		other = line_end(e, e.cursor) + 1
	}
	end := line_end(e, other)
	// The same column, or the end of a shorter line.
	e.cursor = other + len(cut_to_width(text[other:end], col))
	return true
}

@(private = "file")
history_step :: proc(e: ^Editor, dir: int) -> bool {
	next := e.browse + dir
	if next < 0 || next > len(e.history) || len(e.history) == 0 {
		return false
	}
	if e.browse == len(e.history) {
		delete(e.draft)
		e.draft = strings.clone(editor_text(e))
	}
	e.browse = next
	clear(&e.text)
	append(&e.text, e.history[next] if next < len(e.history) else e.draft)
	e.cursor = len(e.text)
	return true
}

@(private = "file")
delete_range :: proc(e: ^Editor, from, to: int) {
	if to <= from {
		return
	}
	remove_range(&e.text, from, to)
	e.cursor = from
	e.browse = len(e.history)
}

@(private = "file")
rune_before :: proc(e: ^Editor, i: int) -> int {
	if i <= 0 {
		return 0
	}
	_, size := utf8.decode_last_rune(e.text[:i])
	return i - size
}

@(private = "file")
rune_after :: proc(e: ^Editor, i: int) -> int {
	if i >= len(e.text) {
		return len(e.text)
	}
	_, size := utf8.decode_rune(e.text[i:])
	return i + size
}

@(private = "file")
is_blank :: proc(b: u8) -> bool {
	return b == ' ' || b == '\n' || b == '\t'
}

// word_start_before is where the word before i starts (or i's own, when i is in
// the middle of one).
@(private = "file")
word_start_before :: proc(e: ^Editor, pos: int) -> int {
	i := pos
	for i > 0 && is_blank(e.text[i - 1]) {
		i -= 1
	}
	for i > 0 && !is_blank(e.text[i - 1]) {
		i -= 1
	}
	return i
}

@(private = "file")
word_end_after :: proc(e: ^Editor, pos: int) -> int {
	i := pos
	for i < len(e.text) && is_blank(e.text[i]) {
		i += 1
	}
	for i < len(e.text) && !is_blank(e.text[i]) {
		i += 1
	}
	return i
}

// line_start is the start of the line (between newlines) that i is in.
@(private = "file")
line_start :: proc(e: ^Editor, pos: int) -> int {
	i := min(pos, len(e.text))
	for i > 0 && e.text[i - 1] != '\n' {
		i -= 1
	}
	return i
}

@(private = "file")
line_end :: proc(e: ^Editor, pos: int) -> int {
	i := pos
	for i < len(e.text) && e.text[i] != '\n' {
		i += 1
	}
	return i
}

// editor_layout breaks the text into the lines drawn in `width` cells (in
// `lines`, which the caller owns) and returns where the cursor is among them.
editor_layout :: proc(e: ^Editor, width: int, lines: ^[dynamic]Line) -> (cx, cy: int) {
	text := editor_text(e)
	wrap(text, width, lines)
	for l, i in lines {
		if e.cursor >= l.start {
			cy = i
		}
	}
	l := lines[cy]
	cx = string_width(text[l.start:min(e.cursor, l.end)])
	// A cursor after a full line would be drawn past the edge.
	if width > 0 && cx >= width {
		cx = width - 1
	}
	return
}
