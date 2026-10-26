#+build !wasi
package client

import "core:fmt"
import "core:testing"

@(test)
test_palette_score :: proc(t: ^testing.T) {
	_, ok := palette_score("", "Mute microphone")
	testing.expect(t, ok, "an empty query matches everything")
	_, ok = palette_score("mm", "Mute microphone")
	testing.expect(t, ok)
	_, ok = palette_score("MUTE", "Mute microphone")
	testing.expect(t, ok, "case is ignored")
	_, ok = palette_score("mute mic", "Mute microphone")
	testing.expect(t, ok, "spaces in the query are ignored")
	_, ok = palette_score("mz", "Mute microphone")
	testing.expect(t, !ok)
	_, ok = palette_score("em", "Mute microphone")
	testing.expect(t, ok)
	_, ok = palette_score("me", "Undeafen")
	testing.expect(t, !ok, "the letters must come in order")

	// Word starts and letters in a row count for more.
	a, _ := palette_score("se", "Search messages")
	b, _ := palette_score("se", "Use the system's theme")
	testing.expect(t, a > b, "\"se\" fits Search better than uSE")
	c, _ := palette_score("dark", "Use the dark theme")
	d, _ := palette_score("dark", "Deafen (hear nobody)")
	testing.expect(t, c > d)
	// A channel's name starts a word after its #.
	e, _ := palette_score("gen", "Go to #general")
	f, _ := palette_score("gen", "Go to #engineering")
	testing.expectf(t, e > f, "gen: general %d, engineering %d", e, f)
}

@(test)
test_palette_matches :: proc(t: ^testing.T) {
	ui := new(UI)
	defer free(ui)
	defer ui_palette_destroy(ui)
	entries := []Palette_Entry {
		{name = "Go to #general"},
		{name = "Go to #random"},
		{name = "Join voice in #general"},
		{name = "Mute microphone"},
	}
	testing.expect_value(t, len(palette_matches(ui, entries, "")), 4)
	got := palette_matches(ui, entries, "general")
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], 0)

	// Among equal matches, the one run last comes first.
	palette_remember(&ui.palette, "Join voice in #general")
	got = palette_matches(ui, entries, "")
	testing.expect_value(t, got[0], 2)
	testing.expect_value(t, got[1], 0)

	// Run again, it moves to the front once, and the list stays short.
	palette_remember(&ui.palette, "Go to #random")
	palette_remember(&ui.palette, "Join voice in #general")
	testing.expect_value(t, len(ui.palette.recent), 2)
	testing.expect_value(t, ui.palette.recent[0], "Join voice in #general")
	for i in 0 ..< 30 {
		palette_remember(&ui.palette, fmt.tprintf("entry %d", i))
	}
	testing.expect_value(t, len(ui.palette.recent), 20)
	testing.expect_value(t, ui.palette.recent[0], "entry 29")
}
