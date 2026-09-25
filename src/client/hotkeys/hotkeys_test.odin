#+build !wasi
package hotkeys

import "core:testing"

@(test)
test_format_parse :: proc(t: ^testing.T) {
	cases := []struct {
		h:    Hotkey,
		text: string,
	} {
		{{}, ""},
		{{.M, {.Ctrl, .Shift}}, "Ctrl+Shift+M"},
		{{.F13, {}}, "F13"},
		{{.Minus, {.Alt}}, "Alt+-"},
		{{.Page_Up, {.Ctrl, .Shift, .Alt, .Super}}, "Ctrl+Shift+Alt+Super+PageUp"},
	}
	for c in cases {
		text := format(c.h, context.temp_allocator)
		testing.expect_value(t, text, c.text)
		h, ok := parse(text)
		testing.expect(t, ok)
		testing.expect_value(t, h, c.h)
	}
}

@(test)
test_parse_forgiving :: proc(t: ^testing.T) {
	h, ok := parse(" shift + ctrl+m ")
	testing.expect(t, ok)
	testing.expect_value(t, h, Hotkey{.M, {.Ctrl, .Shift}})

	h, ok = parse("Cmd+Option+Space")
	testing.expect(t, ok)
	testing.expect_value(t, h, Hotkey{.Space, {.Super, .Alt}})

	h, ok = parse("control+\\")
	testing.expect(t, ok)
	testing.expect_value(t, h, Hotkey{.Backslash, {.Ctrl}})
}

@(test)
test_parse_rejects :: proc(t: ^testing.T) {
	for text in ([]string{"Ctrl", "Ctrl+", "Hyper+M", "Ctrl+Nope", "M+Ctrl", "Ctrl+M+N"}) {
		_, ok := parse(text)
		testing.expectf(t, !ok, "%q should not parse", text)
	}
}

@(test)
test_step_fires_on_press :: proc(t: ^testing.T) {
	w: Watcher
	w.binds[0] = {.M, {.Ctrl}}
	w.binds[1] = {.F13, {}}

	// Ctrl first, then M: fires once, however long it's held.
	testing.expect(t, !step(&w, {mods = {.Ctrl}}))
	testing.expect(t, step(&w, {keys = {.M}, mods = {.Ctrl}}))
	testing.expect(t, !step(&w, {keys = {.M}, mods = {.Ctrl}}))
	testing.expect_value(t, take_fired(&w), 1)
	testing.expect_value(t, take_fired(&w), 0)

	// Released and pressed again: fires again.
	step(&w, {mods = {.Ctrl}})
	testing.expect(t, step(&w, {keys = {.M}, mods = {.Ctrl}}))
	testing.expect_value(t, take_fired(&w), 1)

	// A bind without modifiers.
	step(&w, {})
	testing.expect(t, step(&w, {keys = {.F13}}))
	testing.expect_value(t, take_fired(&w), 2)
}

@(test)
test_step_needs_exact_mods :: proc(t: ^testing.T) {
	w: Watcher
	w.binds[0] = {.M, {.Ctrl}}
	// More modifiers than the bind has, or none: nothing.
	testing.expect(t, !step(&w, {keys = {.M}, mods = {.Ctrl, .Shift}}))
	step(&w, {})
	testing.expect(t, !step(&w, {keys = {.M}}))
	testing.expect_value(t, take_fired(&w), 0)
	// Unbound slots never fire, even when nothing is down.
	step(&w, {})
	testing.expect(t, !step(&w, {keys = {.A}}))
}

@(test)
test_capture :: proc(t: ^testing.T) {
	w: Watcher
	w.binds[0] = {.M, {.Ctrl}}
	step(&w, {keys = {.Q}}) // already down when capturing starts
	capture(&w, true)
	testing.expect(t, capturing(&w))

	// Modifiers alone aren't a hotkey; a key held from before isn't new.
	testing.expect(t, !step(&w, {keys = {.Q}, mods = {.Ctrl}}))
	// The bind's own combination is captured rather than fired.
	testing.expect(t, step(&w, {keys = {.Q, .M}, mods = {.Ctrl}}))
	testing.expect(t, !capturing(&w))
	h, ok := take_captured(&w)
	testing.expect(t, ok)
	testing.expect_value(t, h, Hotkey{.M, {.Ctrl}})
	testing.expect_value(t, take_fired(&w), 0)
	_, ok = take_captured(&w)
	testing.expect(t, !ok)
}
