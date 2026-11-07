package tui

import "core:testing"

@(test)
test_put_string_and_row_text :: proc(t: ^testing.T) {
	b := buffer_make(10, 2)
	defer buffer_destroy(&b)
	end := put_string(&b, 2, 0, "hello", {})
	testing.expect_value(t, end, 7)
	testing.expect_value(t, buffer_row_text(&b, 0), "  hello")
	testing.expect_value(t, buffer_row_text(&b, 1), "")
}

@(test)
test_put_string_clips :: proc(t: ^testing.T) {
	b := buffer_make(5, 1)
	defer buffer_destroy(&b)
	put_string(&b, 3, 0, "abcdef", {})
	testing.expect_value(t, buffer_row_text(&b, 0), "   ab")
	// A limit before the edge.
	buffer_clear(&b)
	put_string(&b, 0, 0, "abcdef", {}, 3)
	testing.expect_value(t, buffer_row_text(&b, 0), "abc")
	// Outside vertically: nothing.
	put_string(&b, 0, 4, "x", {})
	put_string(&b, 0, -1, "x", {})
	testing.expect_value(t, buffer_row_text(&b, 0), "abc")
}

@(test)
test_put_string_left_of_the_edge :: proc(t: ^testing.T) {
	b := buffer_make(6, 1)
	defer buffer_destroy(&b)
	put_string(&b, -2, 0, "abcdef", {})
	testing.expect_value(t, buffer_row_text(&b, 0), "cdef")
	// A wide rune cut in half by the left edge leaves a blank.
	buffer_clear(&b)
	put_string(&b, -1, 0, "日本", {})
	testing.expect_value(t, buffer_row_text(&b, 0), " 本")
}

@(test)
test_wide_runes_take_two_cells :: proc(t: ^testing.T) {
	b := buffer_make(6, 1)
	defer buffer_destroy(&b)
	end := put_string(&b, 0, 0, "a日b", {})
	testing.expect_value(t, end, 4)
	testing.expect_value(t, cell_at(&b, 1, 0).width, 2)
	testing.expect_value(t, cell_at(&b, 2, 0).width, 0)
	testing.expect_value(t, buffer_row_text(&b, 0), "a日b")
	// A wide rune that doesn't fit is not drawn.
	buffer_clear(&b)
	put_string(&b, 4, 0, "日日", {})
	testing.expect_value(t, buffer_row_text(&b, 0), "    日")
}

@(test)
test_overwriting_half_a_wide_rune_blanks_the_other_half :: proc(t: ^testing.T) {
	b := buffer_make(4, 1)
	defer buffer_destroy(&b)
	put_string(&b, 0, 0, "日日", {})
	// On the second half of the first one.
	set_cell(&b, 1, 0, 'x', 1, {})
	testing.expect_value(t, buffer_row_text(&b, 0), " x日")
	// On the first half of the second one.
	set_cell(&b, 2, 0, 'y', 1, {})
	testing.expect_value(t, buffer_row_text(&b, 0), " xy")
	// A wide rune over the halves of two.
	buffer_clear(&b)
	put_string(&b, 0, 0, "日日", {})
	set_cell(&b, 1, 0, '本', 2, {})
	testing.expect_value(t, buffer_row_text(&b, 0), " 本")
}

@(test)
test_zero_width_runes_are_left_out :: proc(t: ^testing.T) {
	b := buffer_make(6, 1)
	defer buffer_destroy(&b)
	end := put_string(&b, 0, 0, "é‍x", {})
	testing.expect_value(t, end, 2)
	testing.expect_value(t, buffer_row_text(&b, 0), "ex")
}

@(test)
test_fill_clips :: proc(t: ^testing.T) {
	b := buffer_make(4, 3)
	defer buffer_destroy(&b)
	fill(&b, {-1, 1, 3, 5}, {}, '#')
	testing.expect_value(t, buffer_row_text(&b, 0), "")
	testing.expect_value(t, buffer_row_text(&b, 1), "##")
	testing.expect_value(t, buffer_row_text(&b, 2), "##")
}
