package main

import "tui"

// What things look like. Colours are the terminal's 256-colour palette, so they
// follow whatever the terminal does with its first 16.

Theme :: struct {
	text:        tui.Style,
	dim:         tui.Style, // times, markers, hints
	own_name:    tui.Style,
	mention:     tui.Style, // a mention of someone
	mention_me:  tui.Style, // a mention of us
	code:        tui.Style,
	link:        tui.Style,
	quote:       tui.Style,
	unread_rule: tui.Style, // the "new messages" line
	reaction:    tui.Style,
	reaction_me: tui.Style,
	selected:    tui.Style, // the row under the cursor in a list
	bar:         tui.Style, // the title and status bars
	badge:       tui.Style, // unread counts
	badge_ping:  tui.Style, // unread mentions
	border:      tui.Style,
	error:       tui.Style,
}

theme := Theme {
	text = {},
	dim = {fg = tui.color_index(244)},
	own_name = {fg = tui.color_index(250), attrs = {.Bold}},
	mention = {fg = tui.color_index(75), attrs = {.Bold}},
	mention_me = {fg = tui.color_index(16), bg = tui.color_index(221), attrs = {.Bold}},
	code = {fg = tui.color_index(180), bg = tui.color_index(236)},
	link = {fg = tui.color_index(39), attrs = {.Underline}},
	quote = {fg = tui.color_index(244)},
	unread_rule = {fg = tui.color_index(203)},
	reaction = {fg = tui.color_index(250), bg = tui.color_index(237)},
	reaction_me = {fg = tui.color_index(117), bg = tui.color_index(24)},
	selected = {fg = tui.color_index(255), bg = tui.color_index(24)},
	bar = {fg = tui.color_index(252), bg = tui.color_index(236)},
	badge = {fg = tui.color_index(16), bg = tui.color_index(250), attrs = {.Bold}},
	badge_ping = {fg = tui.color_index(255), bg = tui.color_index(160), attrs = {.Bold}},
	border = {fg = tui.color_index(240)},
	error = {fg = tui.color_index(203)},
}

// The colours names are drawn in; someone always gets the same one.
NAME_COLORS := [?]u8{167, 108, 179, 110, 175, 73, 209, 114, 147, 215, 104, 180}

name_style :: proc(account: u64) -> tui.Style {
	return {fg = tui.color_index(NAME_COLORS[account % len(NAME_COLORS)]), attrs = {.Bold}}
}
