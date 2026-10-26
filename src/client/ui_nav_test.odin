#+build !wasi
package client

import "core:testing"
import mu "vendor:microui"

@(test)
test_nav_step :: proc(t: ^testing.T) {
	testing.expect_value(t, nav_step(3, -1, false), 0)
	testing.expect_value(t, nav_step(3, -1, true), 2)
	testing.expect_value(t, nav_step(3, 0, false), 1)
	testing.expect_value(t, nav_step(3, 2, false), 0)
	testing.expect_value(t, nav_step(3, 0, true), 2)
	testing.expect_value(t, nav_step(3, 1, true), 0)
}

// nav_test_frame stands in for a frame that drew three buttons and a text box,
// with `keys` pressed.
@(private = "file")
nav_test_frame :: proc(ui: ^UI, keys: bit_set[Extra_Key]) {
	append(&ui.nav.items, Nav_Item{1, {}, nil, -1}, Nav_Item{2, {}, nil, -1})
	append(&ui.nav.items, Nav_Item{3, {}, nil, 5}, Nav_Item{4, {}, nil, -1})
	ui.keys = keys
	nav_frame(ui)
}

@(test)
test_nav_frame :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_nav_destroy(ui)

	nav_test_frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 1)
	testing.expect(t, ui.nav.visible)
	testing.expect(t, .Tab not_in ui.keys, "Tab is taken")

	// Space presses the focused button in the next frame.
	nav_test_frame(ui, {.Activate})
	testing.expect_value(t, ui.nav.activate, 1)
	nav_test_frame(ui, {})
	testing.expect_value(t, ui.nav.activate, 0)

	// Into the text box: it gets microui's focus, with the cursor at the end.
	nav_test_frame(ui, {.Tab})
	nav_test_frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 3)
	testing.expect_value(t, ui.ctx.focus_id, 3)
	testing.expect_value(t, ui.ctx.textbox_state.selection, [2]int{5, 5})
	// Space types in it rather than pressing anything.
	nav_test_frame(ui, {.Activate})
	testing.expect_value(t, ui.nav.activate, 0)

	// And out again.
	nav_test_frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 4)
	testing.expect_value(t, ui.ctx.focus_id, 0)

	// Around the end, and back.
	nav_test_frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 1)
	nav_test_frame(ui, {.Back_Tab})
	testing.expect_value(t, ui.nav.focus, 4)

	// A click hides it.
	ui.ctx.mouse_pressed_bits = {.LEFT}
	nav_test_frame(ui, {})
	ui.ctx.mouse_pressed_bits = {}
	testing.expect_value(t, ui.nav.focus, 0)
	testing.expect(t, !ui.nav.visible)

	// Escape too.
	nav_test_frame(ui, {.Tab})
	nav_test_frame(ui, {.Escape})
	testing.expect(t, !ui.nav.visible)
}

@(test)
test_nav_trap :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_nav_destroy(ui)
	popup := new(mu.Container)
	defer free(popup)

	// A dropdown (1) opened from the keyboard: its list (10, 11) comes last,
	// and Tab and Down stay in it.
	ui.nav.focus, ui.nav.visible = 1, true
	frame := proc(ui: ^UI, popup: ^mu.Container, open: bool, keys: bit_set[Extra_Key]) {
		append(&ui.nav.items, Nav_Item{1, {}, nil, -1}, Nav_Item{2, {}, nil, -1})
		if open {
			append(&ui.nav.items, Nav_Item{10, {}, popup, -1}, Nav_Item{11, {}, popup, -1})
			ui.nav.trap = popup
		}
		ui.keys = keys
		nav_frame(ui)
	}
	nav_focus_next(ui, 10)
	frame(ui, popup, true, {})
	testing.expect_value(t, ui.nav.focus, 10)
	frame(ui, popup, true, {.Tab})
	testing.expect_value(t, ui.nav.focus, 11)
	frame(ui, popup, true, {.Down})
	testing.expect_value(t, ui.nav.focus, 10)
	frame(ui, popup, true, {.Up})
	testing.expect_value(t, ui.nav.focus, 11)

	// Closed: the dropdown has the focus again.
	frame(ui, popup, false, {})
	testing.expect_value(t, ui.nav.focus, 1)
	testing.expect(t, ui.nav.visible)
	frame(ui, popup, false, {.Tab})
	testing.expect_value(t, ui.nav.focus, 2)
}
