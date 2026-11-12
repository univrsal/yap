#+build !wasi
package platform

import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_find_links :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		links: []string, // the URLs link_url returns
	}
	cases := []Case {
		{"no links here", {}},
		{"https://example.com", {"https://example.com"}},
		{"see https://example.com/a?b=c&d=e#f.", {"https://example.com/a?b=c&d=e#f"}},
		{
			"(http://example.com/x) and www.odin-lang.org, ok?",
			{"http://example.com/x", "https://www.odin-lang.org"},
		},
		{
			"https://en.wikipedia.org/wiki/Odin_(disambiguation)!",
			{"https://en.wikipedia.org/wiki/Odin_(disambiguation)"},
		},
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
		testing.expectf(
			t,
			len(links) == len(c.links),
			"%q: got %d links, want %d",
			c.text,
			len(links),
			len(c.links),
		)
		for l, i in links {
			if i < len(c.links) {
				testing.expect_value(t, link_url(c.text, l), c.links[i])
			}
		}
	}
}

@(test)
test_file_openable :: proc(t: ^testing.T) {
	// Pictures, videos, audio, archives and documents, in any case.
	for path in ([]string{"/home/a/Downloads/cat.PNG", `C:\Users\a\Downloads\clip.mp4`, "song.flac", "backup.tar.gz", "report.pdf"}) {
		testing.expectf(t, file_openable(path), "%q should be openable", path)
	}
	// Anything that could run, or that isn't on the list.
	for path in ([]string{"setup.exe", "report.pdf.exe", "evil.msc", "x.appref-ms", "link.webloc", "profile.mobileconfig", "package.deb", "disk.iso", "archive.cab", "no extension", "trailing.", `folder.png\file`, ""}) {
		testing.expectf(t, !file_openable(path), "%q should not be openable", path)
	}
}

// A message is up to 64 KB, and its links are found every time it's drawn, so
// what it takes has to be in proportion to its size.
@(test)
test_find_links_long_input :: proc(t: ^testing.T) {
	cases := [?]string {
		// Closing brackets cut off one at a time used to be counted again each time.
		strings.concatenate(
			{"https://a", strings.repeat(")", 60000, context.temp_allocator)},
			context.temp_allocator,
		),
		strings.concatenate(
			{"https://a(", strings.repeat("]", 60000, context.temp_allocator)},
			context.temp_allocator,
		),
		strings.concatenate(
			{"www.a", strings.repeat(".", 60000, context.temp_allocator)},
			context.temp_allocator,
		),
		strings.repeat("www.a ", 10000, context.temp_allocator),
		strings.repeat("http://", 8000, context.temp_allocator),
	}
	for text in cases {
		started := time.tick_now()
		links := find_links(text)
		took := time.tick_since(started)
		testing.expectf(t, took < 300 * time.Millisecond, "%d bytes took %v", len(text), took)
		testing.expect(t, len(links) > 0)
	}
	// What is cut off stays the same: the brackets that have no partner.
	sentence := "see (https://a.org/x_(y)) and https://b.org/c)."
	links := find_links(sentence)
	testing.expect_value(t, len(links), 2)
	testing.expect_value(t, sentence[links[0].start:links[0].end], "https://a.org/x_(y)")
	testing.expect_value(t, sentence[links[1].start:links[1].end], "https://b.org/c")
}
