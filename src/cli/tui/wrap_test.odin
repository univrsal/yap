package tui

import "core:testing"

@(private = "file")
wrapped :: proc(text: string, width: int) -> []string {
	lines: [dynamic]Line
	defer delete(lines)
	wrap(text, width, &lines)
	out := make([]string, len(lines), context.temp_allocator)
	for l, i in lines {
		out[i] = text[l.start:l.end]
	}
	return out
}

@(private = "file")
expect_lines :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for w, i in want {
		if i < len(got) {
			testing.expect_value(t, got[i], w, loc)
		}
	}
}

@(test)
test_wrap_short_text :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("hello", 10), {"hello"})
	expect_lines(t, wrapped("", 10), {""})
}

@(test)
test_wrap_at_spaces :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("the quick brown fox", 10), {"the quick", "brown fox"})
	expect_lines(t, wrapped("aaa bbb ccc", 7), {"aaa bbb", "ccc"})
	expect_lines(t, wrapped("aaa bbb ccc", 6), {"aaa", "bbb", "ccc"})
}

@(test)
test_wrap_long_words :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("abcdefghij", 4), {"abcd", "efgh", "ij"})
	expect_lines(t, wrapped("ab abcdefgh", 4), {"ab", "abcd", "efgh"})
}

@(test)
test_wrap_newlines :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("a\nb", 10), {"a", "b"})
	expect_lines(t, wrapped("a\n\nb", 10), {"a", "", "b"})
	expect_lines(t, wrapped("a\n", 10), {"a", ""})
	expect_lines(t, wrapped("\n", 10), {"", ""})
}

@(test)
test_wrap_wide_runes :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("日本語", 4), {"日本", "語"})
	// One that is wider than the width still gets its line.
	expect_lines(t, wrapped("日", 1), {"日"})
	expect_lines(t, wrapped("a日", 2), {"a", "日"})
}

@(test)
test_wrap_without_a_width :: proc(t: ^testing.T) {
	expect_lines(t, wrapped("a long line\nsecond", 0), {"a long line", "second"})
}

@(test)
test_wrap_ranges_cover_the_text :: proc(t: ^testing.T) {
	// Everything but the spaces and newlines the breaks are at is in some line.
	text := "word wrap this text, which has 日本語 and\nnewlines and  double  spaces"
	for width in 3 ..= 30 {
		lines: [dynamic]Line
		defer delete(lines)
		wrap(text, width, &lines)
		kept := 0
		for l, i in lines {
			testing.expectf(t, l.start <= l.end, "width %d line %d", width, i)
			if i > 0 {
				testing.expectf(t, l.start >= lines[i - 1].end, "width %d line %d goes back", width, i)
			}
			kept += l.end - l.start
			testing.expectf(
				t,
				string_width(text[l.start:l.end]) <= width || first_rune_size(text[l.start:]) > 0 && string_width(text[l.start:l.end]) == rune_width(first_rune(text[l.start:])),
				"width %d line %q too wide",
				width,
				text[l.start:l.end],
			)
		}
		// The breaks each take one byte at most.
		testing.expectf(t, len(text) - kept <= len(lines), "width %d lost text", width)
	}
}

@(private = "file")
first_rune :: proc(s: string) -> rune {
	r, _ := decode(s, 0)
	return r
}
