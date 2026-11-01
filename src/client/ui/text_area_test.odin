#+build !wasi
package ui

import txt "text"
import "core:testing"
import mu "vendor:microui"

// Every character is 8 pixels wide, and lines are five characters long.
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
test_area_vertical :: proc(t: ^testing.T) {
	ctx := area_test_ctx()
	defer free(ctx)
	text := "abcd\nab\nabcd"
	lines := txt.area_lines(ctx, nil, text, W)
	testing.expect_value(t, len(lines), 3)

	// Down from the end of the first line: the end of the short one.
	x := txt.area_x(ctx, nil, text, lines[0], 4)
	testing.expect_value(t, x, 32)
	at := area_vertical(ctx, nil, text, lines, 4, x, true)
	testing.expect_value(t, at, 7)
	// On down, aiming for the column it started in, not where it is.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, at, x, true), 12)
	testing.expect_value(
		t,
		area_vertical(ctx, nil, text, lines, at, txt.area_x(ctx, nil, text, lines[1], at), true),
		10,
	)
	// And back up.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 12, 32, false), 7)
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 9, 8, false), 6)
	// Past the first line, the start; past the last, the end.
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 2, 16, false), 0)
	testing.expect_value(t, area_vertical(ctx, nil, text, lines, 10, 16, true), len(text))
}
