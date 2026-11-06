package tui

import "core:testing"

@(private = "file")
type :: proc(e: ^Editor, s: string) {
	for r in s {
		editor_key(e, Key_Event{key = .Rune, rune = r})
	}
}

@(private = "file")
press :: proc(e: ^Editor, k: Key, mods := Mods{}) -> bool {
	return editor_key(e, Key_Event{key = k, mods = mods})
}

@(private = "file")
ctrl :: proc(e: ^Editor, r: rune) {
	editor_key(e, Key_Event{key = .Rune, rune = r, mods = {.Ctrl}})
}

@(private = "file")
alt :: proc(e: ^Editor, r: rune) {
	editor_key(e, Key_Event{key = .Rune, rune = r, mods = {.Alt}})
}

@(test)
test_typing_and_backspace :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "héllo 日")
	testing.expect_value(t, editor_text(&e), "héllo 日")
	press(&e, .Backspace)
	testing.expect_value(t, editor_text(&e), "héllo ")
	press(&e, .Backspace)
	press(&e, .Backspace)
	press(&e, .Backspace)
	testing.expect_value(t, editor_text(&e), "hél")
	testing.expect_value(t, e.cursor, 4)
}

@(test)
test_cursor_movement_and_insertion :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "ac")
	press(&e, .Left)
	type(&e, "b")
	testing.expect_value(t, editor_text(&e), "abc")
	press(&e, .Home)
	type(&e, ">")
	press(&e, .End)
	type(&e, "<")
	testing.expect_value(t, editor_text(&e), ">abc<")
	press(&e, .Left)
	press(&e, .Left)
	press(&e, .Delete)
	testing.expect_value(t, editor_text(&e), ">ab<")
	// At the ends nothing happens, and nothing breaks.
	editor_clear(&e)
	press(&e, .Left)
	press(&e, .Backspace)
	press(&e, .Delete)
	press(&e, .Right)
	testing.expect_value(t, editor_text(&e), "")
}

@(test)
test_emacs_keys :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "one two three")
	ctrl(&e, 'w')
	testing.expect_value(t, editor_text(&e), "one two ")
	ctrl(&e, 'a')
	ctrl(&e, 'k')
	testing.expect_value(t, editor_text(&e), "")
	type(&e, "hello world")
	ctrl(&e, 'u')
	testing.expect_value(t, editor_text(&e), "")
	type(&e, "abc")
	ctrl(&e, 'a')
	ctrl(&e, 'f')
	ctrl(&e, 'd')
	testing.expect_value(t, editor_text(&e), "ac")
	ctrl(&e, 'e')
	ctrl(&e, 'b')
	type(&e, "-")
	testing.expect_value(t, editor_text(&e), "a-c")
}

@(test)
test_word_movement :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "alpha beta gamma")
	alt(&e, 'b')
	testing.expect_value(t, e.cursor, 11)
	alt(&e, 'b')
	testing.expect_value(t, e.cursor, 6)
	alt(&e, 'f')
	testing.expect_value(t, e.cursor, 10)
	press(&e, .Left, {.Ctrl})
	testing.expect_value(t, e.cursor, 6)
	press(&e, .Right, {.Ctrl})
	testing.expect_value(t, e.cursor, 10)
	alt(&e, 'd')
	testing.expect_value(t, editor_text(&e), "alpha beta")
}

@(test)
test_unhandled_keys_are_reported :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	testing.expect(t, !press(&e, .Enter))
	testing.expect(t, !press(&e, .Tab))
	testing.expect(t, !press(&e, .Escape))
	testing.expect(t, !press(&e, .Page_Up))
	testing.expect(t, !editor_key(&e, Key_Event{key = .Rune, rune = 'x', mods = {.Ctrl}}))
	testing.expect(t, !editor_key(&e, Key_Event{key = .Rune, rune = 'q', mods = {.Alt}}))
	testing.expect_value(t, editor_text(&e), "")
}

@(test)
test_multiple_lines :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "first")
	testing.expect(t, press(&e, .Enter, {.Alt}))
	type(&e, "second line")
	testing.expect_value(t, editor_text(&e), "first\nsecond line")
	// Up goes to the same column in the line above, or its end.
	press(&e, .Up)
	testing.expect_value(t, e.cursor, 5)
	press(&e, .Home)
	press(&e, .Down)
	testing.expect_value(t, e.cursor, 6)
	press(&e, .End)
	press(&e, .Up)
	testing.expect_value(t, e.cursor, 5)
	// Home and End are of the line.
	press(&e, .Down)
	press(&e, .Home)
	testing.expect_value(t, e.cursor, 6)
	ctrl(&e, 'k')
	testing.expect_value(t, editor_text(&e), "first\n")
	ctrl(&e, 'u')
	testing.expect_value(t, editor_text(&e), "first\n")
}

@(test)
test_history :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	type(&e, "one")
	editor_remember(&e)
	testing.expect_value(t, editor_text(&e), "")
	type(&e, "two")
	editor_remember(&e)
	type(&e, "draft")
	press(&e, .Up)
	testing.expect_value(t, editor_text(&e), "two")
	press(&e, .Up)
	testing.expect_value(t, editor_text(&e), "one")
	testing.expect(t, !press(&e, .Up)) // the oldest
	press(&e, .Down)
	testing.expect_value(t, editor_text(&e), "two")
	press(&e, .Down)
	testing.expect_value(t, editor_text(&e), "draft") // what was being written
	testing.expect(t, !press(&e, .Down))
	// Typing while browsing makes it the draft.
	press(&e, .Up)
	type(&e, "!")
	testing.expect_value(t, editor_text(&e), "two!")
	press(&e, .Up)
	testing.expect_value(t, editor_text(&e), "two") // it started again from the newest
}

@(test)
test_history_skips_repeats_and_empty :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	editor_remember(&e)
	type(&e, "same")
	editor_remember(&e)
	type(&e, "same")
	editor_remember(&e)
	testing.expect_value(t, len(e.history), 1)
	for i in 0 ..< HISTORY_MAX + 5 {
		type(&e, "x")
		for _ in 0 ..< i {
			type(&e, "y")
		}
		editor_remember(&e)
	}
	testing.expect_value(t, len(e.history), HISTORY_MAX)
}

@(test)
test_set_and_insert :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	editor_set(&e, "edit me")
	testing.expect_value(t, e.cursor, 7)
	press(&e, .Home)
	editor_insert(&e, "pasted\nlines ")
	testing.expect_value(t, editor_text(&e), "pasted\nlines edit me")
	testing.expect_value(t, e.cursor, 13)
}

@(test)
test_layout_cursor :: proc(t: ^testing.T) {
	e: Editor
	defer editor_destroy(&e)
	lines: [dynamic]Line
	defer delete(lines)

	editor_set(&e, "hello world")
	cx, cy := editor_layout(&e, 20, &lines)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, cx, 11)
	testing.expect_value(t, cy, 0)

	// Wrapped: the cursor is on the second line.
	clear(&lines)
	cx, cy = editor_layout(&e, 7, &lines)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, cy, 1)
	testing.expect_value(t, cx, 5)

	// With newlines, and wide runes.
	clear(&lines)
	editor_set(&e, "ab\n日本")
	cx, cy = editor_layout(&e, 20, &lines)
	testing.expect_value(t, cy, 1)
	testing.expect_value(t, cx, 4)

	// Nothing typed: one empty line.
	clear(&lines)
	editor_clear(&e)
	cx, cy = editor_layout(&e, 20, &lines)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, cx, 0)
	testing.expect_value(t, cy, 0)
}
