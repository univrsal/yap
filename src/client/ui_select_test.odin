#+build !wasi
package client

import "core:math"
import "core:strings"
import "core:testing"
import mu "vendor:microui"

// Every character is 8 pixels wide and lines are 16 tall.
@(private = "file")
CHAR_W :: 8

@(private = "file")
Select_Test :: struct {
	ui:    ^UI,
	lines: []string,
	rects: [dynamic]mu.Rect, // where each line went, last frame
}

@(private = "file")
select_test_init :: proc(t: ^Select_Test, lines: []string) {
	t.ui = new(UI)
	t.lines = lines
	mu.init(&t.ui.ctx)
	t.ui.ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * CHAR_W}
	t.ui.ctx.text_height = proc(font: mu.Font) -> i32 {return 16}
}

@(private = "file")
select_test_destroy :: proc(t: ^Select_Test) {
	ui_select_destroy(t.ui)
	delete(t.rects)
	free(t.ui)
}

// frame lays out a panel of lines, one item each, the way log_panel does.
@(private = "file")
frame :: proc(t: ^Select_Test) {
	ctx := &t.ui.ctx
	clear(&t.rects)
	mu.begin(ctx)
	if mu.begin_window(ctx, "w", {0, 0, 400, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, "p")
		select_begin(t.ui, .Log)
		for text, i in t.lines {
			mu.layout_row(ctx, {-1}, 16)
			r := mu.layout_next(ctx)
			append(&t.rects, r)
			select_item(t.ui, i64(i), text)
			select_line(t.ui, i64(i), text, 0, len(text), {r.x, r.y})
		}
		select_end(t.ui)
		mu.end_panel(ctx)
		mu.end_window(ctx)
	}
	mu.end(ctx)
}

// at is the point over character `ch` of line `line`, a little into it.
@(private = "file")
at :: proc(t: ^Select_Test, line, ch: int) -> (x, y: i32) {
	r := t.rects[line]
	return r.x + i32(ch) * CHAR_W + 1, r.y + 4
}

@(private = "file")
drag :: proc(t: ^Select_Test, from_line, from_ch, to_line, to_ch: int) {
	ctx := &t.ui.ctx
	x, y := at(t, from_line, from_ch)
	mu.input_mouse_move(ctx, x, y)
	frame(t)
	mu.input_mouse_down(ctx, x, y, .LEFT)
	frame(t)
	x, y = at(t, to_line, to_ch)
	mu.input_mouse_move(ctx, x, y)
	frame(t)
	mu.input_mouse_up(ctx, x, y, .LEFT)
	frame(t)
	frame(t)
}

@(test)
test_select_within_a_line :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"hello world", "second line"})
	defer select_test_destroy(&st)
	frame(&st)

	drag(&st, 0, 6, 0, 11)
	testing.expect(t, has_selection(&st.ui.select, .Log))
	testing.expect_value(t, strings.to_string(st.ui.select.text), "world")
}

@(test)
test_select_across_lines :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"hello world", "second line", "third"})
	defer select_test_destroy(&st)
	frame(&st)

	// Backwards, from the third line into the first: the same text.
	drag(&st, 2, 3, 0, 6)
	testing.expect_value(t, strings.to_string(st.ui.select.text), "world\nsecond line\nthi")
}

@(test)
test_select_past_the_end :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"short", "line"})
	defer select_test_destroy(&st)
	frame(&st)

	// Right of the text takes the rest of the line.
	drag(&st, 0, 2, 0, 30)
	testing.expect_value(t, strings.to_string(st.ui.select.text), "ort")
}

@(test)
test_click_clears_selection :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"hello world"})
	defer select_test_destroy(&st)
	frame(&st)

	drag(&st, 0, 0, 0, 5)
	testing.expect(t, has_selection(&st.ui.select, .Log))
	drag(&st, 0, 3, 0, 3)
	testing.expect(t, !has_selection(&st.ui.select, .Log))
	testing.expect_value(t, strings.to_string(st.ui.select.text), "")
}

// A font whose characters aren't a whole number of pixels wide, measured
// the way the renderer does: the sum, rounded up.
@(private = "file")
FRACTIONAL_W :: 7.4

@(private = "file")
fractional_width :: proc(font: mu.Font, s: string) -> i32 {
	return i32(math.ceil(f32(len(s)) * FRACTIONAL_W))
}

// selection_rect is the rect last frame painted the selection with.
@(private = "file")
selection_rect :: proc(t: ^Select_Test) -> (rect: mu.Rect, ok: bool) {
	cmd: ^mu.Command
	for variant in mu.next_command_iterator(&t.ui.ctx, &cmd) {
		if r, is_rect := variant.(^mu.Command_Rect); is_rect && r.color == SELECTION_COLOR {
			return r.rect, true
		}
	}
	return
}

// Dragging to the left from where the button went down leaves the
// selection's right edge where it is, whatever the widths round to.
@(test)
test_selection_edge_stays_put :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"the quick brown fox jumps over the lazy dog"})
	defer select_test_destroy(&st)
	ctx := &st.ui.ctx
	ctx.text_width = fractional_width
	frame(&st)

	r := st.rects[0]
	x_of :: proc(r: mu.Rect, ch: int) -> i32 {
		return r.x + i32(f32(ch) * FRACTIONAL_W) + 1
	}
	ANCHOR :: 30
	mu.input_mouse_move(ctx, x_of(r, ANCHOR), r.y + 4)
	frame(&st)
	mu.input_mouse_down(ctx, x_of(r, ANCHOR), r.y + 4, .LEFT)
	frame(&st)
	want := r.x + fractional_width(nil, st.lines[0][:ANCHOR])
	for ch := ANCHOR - 1; ch >= 0; ch -= 1 {
		mu.input_mouse_move(ctx, x_of(r, ch), r.y + 4)
		frame(&st)
		frame(&st) // the focus moves in one frame and is painted in the next
		rect, ok := selection_rect(&st)
		if !testing.expectf(t, ok, "nothing selected with the pointer on character %d", ch) {
			continue
		}
		testing.expectf(
			t,
			rect.x + rect.w == want,
			"right edge at %d with the pointer on character %d, want %d",
			rect.x + rect.w,
			ch,
			want,
		)
	}
}

// The pointer picks the character it's on at the far end of a long line
// as well as at the start.
@(test)
test_select_far_along_a_line :: proc(t: ^testing.T) {
	st: Select_Test
	select_test_init(&st, {"the quick brown fox jumps over the lazy dog"})
	defer select_test_destroy(&st)
	ctx := &st.ui.ctx
	ctx.text_width = fractional_width
	frame(&st)

	r := st.rects[0]
	x_of :: proc(r: mu.Rect, ch: int) -> i32 {
		return r.x + i32(f32(ch) * FRACTIONAL_W) + 1
	}
	mu.input_mouse_move(ctx, x_of(r, 35), r.y + 4)
	frame(&st)
	mu.input_mouse_down(ctx, x_of(r, 35), r.y + 4, .LEFT)
	frame(&st)
	mu.input_mouse_move(ctx, x_of(r, 39), r.y + 4)
	frame(&st)
	mu.input_mouse_up(ctx, x_of(r, 39), r.y + 4, .LEFT)
	frame(&st)
	frame(&st)
	testing.expect_value(t, strings.to_string(st.ui.select.text), "lazy")
}
