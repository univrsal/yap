#+build !wasi
package client

import "core:testing"

@(test)
test_history :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_history_destroy(ui)
	ns := new(Net_Session)
	defer free(ns)
	append(&ui.sessions, ns)
	defer delete(ui.sessions)
	ui.session, ui.view, ui.narrow = ns, &ns.view, true

	// Channels, settings, a category, back to the channels.
	history_frame(ui)
	ui.channels.show_list = true
	history_frame(ui)
	ui.page = .Settings
	ui.settings_list = true
	history_frame(ui)
	ui.settings_list = false
	ui.settings_client = .Audio
	history_frame(ui)
	testing.expect_value(t, len(ui.history.places), 4)

	// Back is the list of categories, then the channels.
	ui.history.request = -1
	history_frame(ui)
	testing.expect(t, ui.page == .Settings && ui.settings_list)
	ui.history.request = -1
	history_frame(ui)
	testing.expect(t, ui.page == .Main && ui.channels.show_list)
	// Where it went isn't recorded as new.
	history_frame(ui)
	history_frame(ui)
	testing.expect_value(t, len(ui.history.places), 4)
	testing.expect_value(t, ui.history.at, 1)

	// Forward again, twice, and one more has nowhere to go.
	ui.history.request = 1
	history_frame(ui)
	ui.history.request = 1
	history_frame(ui)
	ui.history.request = 1
	history_frame(ui)
	testing.expect(t, ui.page == .Settings && !ui.settings_list)
	testing.expect_value(t, ui.history.at, 3)

	// Going somewhere new from the middle drops what was forward.
	ui.history.request = -1
	history_frame(ui)
	history_frame(ui) // it has arrived
	ui.page = .Main
	ui.channels.show_list = false
	history_frame(ui)
	testing.expect_value(t, len(ui.history.places), 4)

	// Only twelve are kept.
	for i in 0 ..< 30 {
		ui.channels.show_list = i % 2 == 0
		history_frame(ui)
	}
	testing.expect_value(t, len(ui.history.places), HISTORY_LIMIT)
}
