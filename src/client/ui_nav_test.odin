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
	append(&ui.nav.items, Nav_Item{1, {}, nil, nil, -1, 0, false}, Nav_Item{2, {}, nil, nil, -1, 0, false})
	append(&ui.nav.items, Nav_Item{3, {}, nil, nil, 5, 0, false}, Nav_Item{4, {}, nil, nil, -1, 0, false})
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
		append(&ui.nav.items, Nav_Item{1, {}, nil, nil, -1, 0, false}, Nav_Item{2, {}, nil, nil, -1, 0, false})
		if open {
			append(&ui.nav.items, Nav_Item{10, {}, popup, nil, -1, 0, false}, Nav_Item{11, {}, popup, nil, -1, 0, false})
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

@(test)
test_nav_opened_window :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_nav_destroy(ui)
	main, win := new(mu.Container), new(mu.Container)
	defer free(main)
	defer free(win)
	win.zindex = 1

	frame := proc(ui: ^UI, main, win: ^mu.Container, open: bool, keys: bit_set[Extra_Key]) {
		ui.ctx.frame += 1
		append(&ui.nav.items, Nav_Item{1, {}, main, nil, -1, 0, false}, Nav_Item{2, {}, main, nil, -1, 0, false})
		if open {
			append(&ui.nav.items, Nav_Item{10, {}, win, nil, -1, 0, false}, Nav_Item{11, {}, win, nil, -1, 0, false})
		}
		ui.keys = keys
		nav_frame(ui)
	}
	// Space on button 2 opens a window a frame later: its first control gets
	// the focus.
	frame(ui, main, win, false, {.Tab})
	frame(ui, main, win, false, {.Tab})
	testing.expect_value(t, ui.nav.focus, 2)
	frame(ui, main, win, false, {.Activate})
	frame(ui, main, win, false, {}) // button 2 is pressed
	frame(ui, main, win, true, {})
	testing.expect_value(t, ui.nav.focus, 10)

	// F6 goes back to the main window, and on to the window again.
	frame(ui, main, win, true, {.Next_Area})
	testing.expect_value(t, ui.nav.focus, 1)
	frame(ui, main, win, true, {.Next_Area})
	testing.expect_value(t, ui.nav.focus, 10)
	frame(ui, main, win, true, {.Prev_Area})
	testing.expect_value(t, ui.nav.focus, 1)

	// A window that was already open doesn't take the focus again.
	frame(ui, main, win, true, {.Activate})
	frame(ui, main, win, true, {})
	frame(ui, main, win, true, {})
	testing.expect_value(t, ui.nav.focus, 1)

	// Closed while it has the focus: back to button 2, which opened it.
	frame(ui, main, win, true, {.Next_Area})
	testing.expect_value(t, ui.nav.focus, 10)
	frame(ui, main, win, false, {})
	testing.expect_value(t, ui.nav.focus, 2)
	testing.expect(t, ui.nav.visible)
}

@(test)
test_nav_list :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_nav_destroy(ui)

	// A button, a list of three with the second selected, and a button.
	frame := proc(ui: ^UI, keys: bit_set[Extra_Key]) {
		append(&ui.nav.items, Nav_Item{1, {}, nil, nil, -1, 0, false})
		append(&ui.nav.items, Nav_Item{10, {}, nil, nil, -1, 10, false})
		append(&ui.nav.items, Nav_Item{11, {}, nil, nil, -1, 10, true})
		append(&ui.nav.items, Nav_Item{12, {}, nil, nil, -1, 10, false})
		append(&ui.nav.items, Nav_Item{2, {}, nil, nil, -1, 0, false})
		ui.keys = keys
		nav_frame(ui)
	}
	frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 1)
	// Into the list at its selected row.
	frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 11)
	// Up and Down move in it, and stop at its ends.
	frame(ui, {.Down})
	testing.expect_value(t, ui.nav.focus, 12)
	frame(ui, {.Down})
	testing.expect_value(t, ui.nav.focus, 12)
	frame(ui, {.Up})
	frame(ui, {.Up})
	frame(ui, {.Up})
	testing.expect_value(t, ui.nav.focus, 10)
	// Tab leaves it, from any row; Shift+Tab goes back in at the selected one.
	frame(ui, {.Tab})
	testing.expect_value(t, ui.nav.focus, 2)
	frame(ui, {.Back_Tab})
	testing.expect_value(t, ui.nav.focus, 11)
	frame(ui, {.Back_Tab})
	testing.expect_value(t, ui.nav.focus, 1)
	// Up and Down outside a list are left alone.
	frame(ui, {.Down})
	testing.expect_value(t, ui.nav.focus, 1)
	testing.expect(t, .Down in ui.keys)
}

@(test)
test_nav_scroll_into_view :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_nav_destroy(ui)
	panel := new(mu.Container)
	defer free(panel)
	panel.body = {0, 0, 100, 100}
	style := mu.Style{} // no padding
	ui.ctx.style = &style

	// Below the panel's body: scrolled down by as much as it sticks out.
	append(&ui.nav.items, Nav_Item{1, {0, 150, 100, 20}, nil, panel, -1, 0, false})
	ui.keys = {.Tab}
	nav_frame(ui)
	testing.expect_value(t, ui.nav.focus, 1)
	testing.expect_value(t, panel.scroll.y, 150 + 20 - 100)

	// Above it: back up, not past the top.
	panel.scroll.y = 30
	append(&ui.nav.items, Nav_Item{1, {0, 150, 100, 20}, nil, panel, -1, 0, false})
	append(&ui.nav.items, Nav_Item{2, {0, -50, 100, 20}, nil, panel, -1, 0, false})
	ui.keys = {.Tab}
	nav_frame(ui)
	testing.expect_value(t, ui.nav.focus, 2)
	testing.expect_value(t, panel.scroll.y, 0)
}
