package client

import "core:sync"

import "client:conn"
import "common:proto"

// Back and forward through the screens of a narrow window, with the mouse's
// extra buttons (the thumb buttons on some mice).
//
// A narrow window shows one screen at a time: a server's channel list, a
// channel, the settings (their list, then a category), the inbox (its list,
// then a conversation). Nothing there says where we came from, so each frame
// compares where we are with where the last frame was, and a change is a step
// in the history. Going back or forward puts the UI back where it was, and the
// next frames are not recorded until it has got there (a channel is switched
// by the network side, a frame or more later).

// How many places are kept.
HISTORY_LIMIT :: 12

// How many frames a jump may take to arrive before it is given up on.
@(private = "file")
HISTORY_SETTLE_FRAMES :: 30

// History_Place is everything that says which screen is shown. Fields that the
// page doesn't use are cleared, so that two places on the same screen are equal.
History_Place :: struct {
	session:       ^Net_Session,
	page:          Page,
	conv:          proto.Conv_Id, // Main: the conversation being viewed
	list:          bool, // Main: the channel list instead of it
	settings_list: bool, // Settings: the list of categories
	tab:           Settings_Tab,
	client:        Client_Category,
	server:        Server_Category,
	dm:            proto.Account_Id, // Buddies: the DM or group open, if any
	group:         proto.Conv_Id,
}

UI_History :: struct {
	places:  [dynamic]History_Place,
	at:      int, // the place we are at, in `places`
	// Steps asked for by the mouse buttons, to be taken in the next frame:
	// -1 for back, 1 for forward.
	request: int,
	// The place being gone to, until the UI shows it (or HISTORY_SETTLE_FRAMES
	// have passed).
	target:  History_Place,
	settle:  int,
}

ui_history_destroy :: proc(ui: ^UI) {
	delete(ui.history.places)
	ui.history = {}
}

// history_place is where the UI is now. Call between frames, with no View
// locked.
@(private = "file")
history_place :: proc(ui: ^UI) -> History_Place {
	p := History_Place {
		session = ui.session,
		page    = ui.page,
	}
	switch ui.page {
	case .Main:
		p.list = ui.channels.show_list
		v := ui.view
		sync.guard(&v.mutex)
		p.conv = v.viewing
	case .Settings:
		p.settings_list = ui.settings_list
		p.tab = ui.settings_tab
		p.client = ui.settings_client
		p.server = ui.settings_server
	case .Buddies:
		p.dm, p.group = ui.buddies.selected, ui.buddies.selected_group
	}
	return p
}

// history_go puts the UI at `p`. A server that is gone is reported by false.
@(private = "file")
history_go :: proc(ui: ^UI, p: History_Place) -> bool {
	found := false
	for ns in ui.sessions {
		found ||= ns == p.session
	}
	if !found {
		return false
	}
	if p.session != ui.session {
		join_close(ui)
		show_session(ui, p.session)
	}
	switch p.page {
	case .Main:
		ui.page = .Main
		ui.channels.show_list = p.list
		if p.conv != 0 {
			shown: proto.Conv_Id
			{
				v := ui.view
				sync.guard(&v.mutex)
				shown = v.viewing
			}
			if shown != p.conv {
				command(ui, conn.View_Command{conv = p.conv})
			}
		}
	case .Settings:
		open_settings(ui)
		ui.settings_list = p.settings_list
		ui.settings_tab = p.tab
		ui.settings_client = p.client
		ui.settings_server = p.server
	case .Buddies:
		switch {
		case p.dm != 0:
			open_conversation(ui, p.dm)
		case p.group != 0:
			open_group(ui, p.group)
		case:
			ui.page = .Buddies
			ui.buddies.selected, ui.buddies.selected_group = 0, 0
		}
	}
	ui_redraw(ui)
	return true
}

// history_step moves `step` places through the history, skipping those that
// can't be shown any more.
@(private = "file")
history_step :: proc(ui: ^UI, step: int) {
	h := &ui.history
	for i := h.at + step; i >= 0 && i < len(h.places); i += step {
		if history_go(ui, h.places[i]) {
			h.at = i
			h.target, h.settle = h.places[i], HISTORY_SETTLE_FRAMES
			return
		}
	}
}

// history_frame records where the UI is, and takes the steps that the mouse
// buttons asked for. Call between frames, with no View locked.
history_frame :: proc(ui: ^UI) {
	h := &ui.history
	step := h.request
	h.request = 0
	if !ui.narrow || ui.session == nil {
		return
	}
	if step != 0 {
		history_step(ui, step)
		return
	}
	here := history_place(ui)
	if h.settle > 0 {
		h.settle -= 1
		if here != h.target && h.settle > 0 {
			return
		}
		h.settle = 0
	}
	if len(h.places) > 0 && h.places[h.at] == here {
		return
	}
	// Anything forward of here is lost, as in a browser.
	resize(&h.places, h.at + 1 if len(h.places) > 0 else 0)
	append(&h.places, here)
	if len(h.places) > HISTORY_LIMIT {
		ordered_remove(&h.places, 0)
	}
	h.at = len(h.places) - 1
}
