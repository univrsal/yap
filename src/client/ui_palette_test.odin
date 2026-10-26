#+build !wasi
package client

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
}
