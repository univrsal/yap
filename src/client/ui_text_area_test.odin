#+build !wasi
package client

import "core:testing"
import mu "vendor:microui"

// Every character is 8 pixels wide; lines are five characters.
@(private = "file")
W :: 5 * 8

@(private = "file")
area_test_ctx :: proc() -> ^mu.Context {
	ctx := new(mu.Context)
	mu.init(ctx)
	ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * 8}
	ctx.text_height = proc(font: mu.Font) -> i32 {return 16}
	return ctx
}

@(test)
test_area_lines :: proc(t: ^testing.T) {
	ctx := area_test_ctx()
	defer free(ctx)
	cases := [?]struct {
		text:  string,
		lines: []Area_Line,
	} {
		{"", {{0, 0, 0}}},
		{"ab", {{0, 2, 2}}},
		// A newline at the end: an empty line after it, for the caret.
		{"ab\n", {{0, 2, 2}, {3, 3, 3}}},
		{"\n", {{0, 0, 0}, {1, 1, 1}}},
		{"ab\ncd", {{0, 2, 2}, {3, 5, 5}}},
		{"a\n\nb", {{0, 1, 1}, {2, 2, 2}, {3, 4, 4}}},
		// Wrapped at a space: the space is the first line's, its last place.
		{"aaaa bbbb", {{0, 4, 4}, {5, 9, 9}}},
		// A word broken where it didn't fit.
		{"abcdefg", {{0, 5, 4}, {5, 7, 7}}},
		// Wrapped at spaces right before a newline: one break, not two.
		{"aaaa  \nbb", {{0, 4, 6}, {7, 9, 9}}},
	}
	for c in cases {
		got := area_lines(ctx, nil, c.text, W)
		testing.expectf(t, len(got) == len(c.lines), "%q: %v, not %v", c.text, got, c.lines)
		if len(got) != len(c.lines) {
			continue
		}
		for l, i in got {
			testing.expectf(t, l == c.lines[i], "%q line %d: %v, not %v", c.text, i, l, c.lines[i])
		}
		// Every place in the text is on a line, in order.
		last := 0
		for at in 0 ..= len(c.text) {
			i := area_line_of(got, at)
			testing.expectf(
				t,
				i >= last && got[i].start <= at && at <= got[i].stop,
				"%q: %d on line %d",
				c.text,
				at,
				i,
			)
			last = i
		}
	}
}

@(test)
test_area_vertical :: proc(t: ^testing.T) {
	ctx := area_test_ctx()
	defer free(ctx)
	text := "abcd\nab\nabcd"
	lines := area_lines(ctx, nil, text, W)
	testing.expect_value(t, len(lines), 3)

	// Down from the end of the first line: the end of the short one.
	x := area_x(ctx, nil, text, lines[0], 4)
	testing.expect_value(t, x, 32)
	at := area_vertical(ctx, nil, text, lines, 4, x, true)
	testing.expect_value(t, at, 7)
	// On down, aiming for the column it started in, not where it is.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, at, x, true), 12)
	testing.expect_value(
		t,
		area_vertical(ctx, nil, text, lines, at, area_x(ctx, nil, text, lines[1], at), true),
		10,
	)
	// And back up.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 12, 32, false), 7)
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 9, 8, false), 6)
	// Past the first line, the start; past the last, the end.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 2, 16, false), 0)
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 10, 16, true), len(text))
}
