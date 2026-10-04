#+build !wasi
package client

import "core:testing"
import mu "vendor:microui"

@(test)
test_wrapped_lines :: proc(t: ^testing.T) {
	ctx := new(mu.Context)
	defer free(ctx)
	mu.init(ctx)
	// Every character is 8 pixels wide.
	ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * 8}
	ctx.text_height = proc(font: mu.Font) -> i32 {return 16}

	W :: 5 * 8 // five characters
	cases := [?]struct {
		text:  string,
		lines: i32,
	} {
		{"short", 1},
		{"a\nb", 2},
		// A blank line is a line.
		{"a\n\nb", 3},
		{"aaaa bbbb\ncc", 3},
		{"aaaaa\ncc", 2},
		// Wrapped at spaces right before a newline: no blank line for it.
		{"aaaa  \ncc", 2},
		{"abcdefghij", 2},
	}
	for c in cases {
		got := wrapped_lines(ctx, c.text, W)
		testing.expectf(t, got == c.lines, "%q: %d lines, not %d", c.text, got, c.lines)
	}
}
