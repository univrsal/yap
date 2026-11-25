#+build !wasi
package client

import "core:slice"
import "core:testing"

@(test)
test_spell_default_languages :: proc(t: ^testing.T) {
	windows := []string{"de-AT", "de-CH", "de-DE", "en-AU", "en-GB", "en-US"}
	mac := []string{"de", "en", "en-GB", "fr", "sr", "sr-Latn"}
	linux := []string{"de-BE", "de-DE", "en-GB", "en-US"}
	cases := [?]struct {
		have:   []string,
		locale: string,
		want:   []string,
	} {
		{windows, "de-DE", {"de-DE", "en-US"}},
		{windows, "de-AT", {"de-AT", "en-US"}},
		{windows, "en-GB", {"en-GB"}},
		{windows, "fr-FR", {"en-US"}},
		{windows, "", {"en-US"}},
		{mac, "de_DE.UTF-8", {"de", "en"}},
		{mac, "en_GB.UTF-8", {"en-GB"}},
		{mac, "C", {"en"}},
		{mac, "sr-Latn-RS", {"sr", "en"}},
		// The country isn't there: the language's main country.
		{linux, "de_AT.UTF-8@euro", {"de-DE", "en-US"}},
		{linux, "en_AU.UTF-8", {"en-US"}},
		{[]string{"en-GB"}, "en_US", {"en-GB"}},
		{nil, "de-DE", {}},
	}
	for c in cases {
		got := spell_default_languages(c.have, c.locale)
		testing.expectf(
			t,
			slice.equal(got, c.want),
			"%v, %q: %v, not %v",
			c.have,
			c.locale,
			got,
			c.want,
		)
	}
}

@(test)
test_code_ranges :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		code: [][2]int,
	} {
		{"no code", {}},
		{"a `b` c", {{2, 5}}},
		{"a ``b ` c`` d", {{2, 11}}},
		// Not closed: not code.
		{"a `b c", {}},
		{"`a` and `b`", {{0, 3}, {8, 11}}},
		// A span doesn't go past the end of its line.
		{"a `b\nc` d", {}},
		{"x\n```\ncode\n```\ny `z`", {{2, 14}, {17, 20}}},
		// A block that isn't closed goes on to the end.
		{"x\n```go\ncode", {{2, 12}}},
	}
	for c in cases {
		got := code_ranges(c.text)
		testing.expectf(t, slice.equal(got, c.code), "%q: %v, not %v", c.text, got, c.code)
	}
}
