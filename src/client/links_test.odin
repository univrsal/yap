#+build !wasi
package client

import "core:testing"

@(test)
test_find_links :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		links: []string, // the URLs link_url gives
	}
	cases := []Case {
		{"no links here", {}},
		{"https://example.com", {"https://example.com"}},
		{"see https://example.com/a?b=c&d=e#f.", {"https://example.com/a?b=c&d=e#f"}},
		{"(http://example.com/x) and www.odin-lang.org, ok?", {"http://example.com/x", "https://www.odin-lang.org"}},
		{"https://en.wikipedia.org/wiki/Odin_(disambiguation)!", {"https://en.wikipedia.org/wiki/Odin_(disambiguation)"}},
		{"HTTPS://Example.COM/Path", {"HTTPS://Example.COM/Path"}},
		{"<https://a.example>\"https://b.example\"", {"https://a.example", "https://b.example"}},
		{"https://ü.example/ö then text", {"https://ü.example/ö"}},
		// Not links: mid-word, prefix only, other schemes.
		{"xhttps://example.com", {}},
		{"just https:// and www.", {}},
		{"ftp://example.com javascript:alert(1) file:///etc/passwd", {}},
	}
	for c in cases {
		links := find_links(c.text)
		testing.expectf(t, len(links) == len(c.links), "%q: got %d links, want %d", c.text, len(links), len(c.links))
		for l, i in links {
			if i < len(c.links) {
				testing.expect_value(t, link_url(c.text, l), c.links[i])
			}
		}
	}
}
