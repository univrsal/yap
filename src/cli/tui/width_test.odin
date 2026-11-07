package tui

import "core:testing"

@(test)
test_rune_width :: proc(t: ^testing.T) {
	testing.expect_value(t, rune_width('a'), 1)
	testing.expect_value(t, rune_width('é'), 1)
	testing.expect_value(t, rune_width('\t'), 0)
	testing.expect_value(t, rune_width('\n'), 0)
	testing.expect_value(t, rune_width(0x0301), 0) // combining acute
	testing.expect_value(t, rune_width(0x200d), 0) // zero width joiner
	testing.expect_value(t, rune_width(0xfe0f), 0) // variation selector 16
	testing.expect_value(t, rune_width('日'), 2)
	testing.expect_value(t, rune_width('한'), 2)
	testing.expect_value(t, rune_width('Ａ'), 2) // fullwidth A
	testing.expect_value(t, rune_width('😀'), 2)
	testing.expect_value(t, rune_width('👍'), 2)
	testing.expect_value(t, rune_width(0x1f3fd), 0) // skin tone
	testing.expect_value(t, rune_width('─'), 1) // box drawing stays narrow
	testing.expect_value(t, rune_width('↩'), 1)
}

@(test)
test_string_width :: proc(t: ^testing.T) {
	testing.expect_value(t, string_width(""), 0)
	testing.expect_value(t, string_width("hello"), 5)
	testing.expect_value(t, string_width("日本語"), 6)
	testing.expect_value(t, string_width("a😀b"), 4)
	testing.expect_value(t, string_width("é"), 1)
}

@(test)
test_cut_to_width :: proc(t: ^testing.T) {
	testing.expect_value(t, cut_to_width("hello", 3), "hel")
	testing.expect_value(t, cut_to_width("hello", 10), "hello")
	// A wide character that doesn't fit is left out whole.
	testing.expect_value(t, cut_to_width("a日本", 2), "a")
	testing.expect_value(t, cut_to_width("a日本", 3), "a日")
	testing.expect_value(t, cut_to_width("x", 0), "")
}

@(test)
test_ranges_sorted :: proc(t: ^testing.T) {
	// The binary search needs them sorted and apart.
	check :: proc(t: ^testing.T, ranges: []Range) {
		for r, i in ranges {
			testing.expectf(t, r.lo <= r.hi, "range %d reversed", i)
			if i > 0 {
				testing.expectf(t, ranges[i - 1].hi < r.lo, "range %d overlaps the one before", i)
			}
		}
	}
	check(t, ZERO_WIDTH[:])
	check(t, WIDE[:])
}
