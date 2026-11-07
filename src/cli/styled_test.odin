package main

import "core:strings"
import "core:testing"

import "client:richtext"
import "tui"

@(private = "file")
plain :: proc(lines: [][]Seg) -> []string {
	out := make([]string, len(lines), context.temp_allocator)
	for line, i in lines {
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		for s in line {
			strings.write_string(&b, s.text)
		}
		out[i] = strings.to_string(b)
	}
	return out
}

@(test)
test_styled_plain_text :: proc(t: ^testing.T) {
	lines := styled_lines("hello world", nil, 40, {})
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, plain(lines)[0], "hello world")
}

@(test)
test_styled_markdown :: proc(t: ^testing.T) {
	lines := styled_lines("a **bold** and *slanted* and `code` word", nil, 60, {})
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, plain(lines)[0], "a bold and slanted and code word")
	bold, italic, code := false, false, false
	for s in lines[0] {
		switch s.text {
		case "bold": bold = .Bold in s.style.attrs
		case "slanted": italic = .Italic in s.style.attrs
		case "code": code = s.style.bg == theme.code.bg
		case:
			testing.expectf(t, s.style.attrs == {}, "%q should be plain", s.text)
		}
	}
	testing.expect(t, bold && italic && code)
}

@(test)
test_styled_wraps :: proc(t: ^testing.T) {
	lines := styled_lines("one two three four five six", nil, 12, {})
	got := plain(lines)
	testing.expect(t, len(got) >= 3)
	for g in got {
		testing.expectf(t, tui.string_width(g) <= 12, "%q is too wide", g)
	}
	testing.expect_value(t, strings.join(got, " ", context.temp_allocator), "one two three four five six")
}

@(test)
test_styled_lists_and_quotes :: proc(t: ^testing.T) {
	lines := styled_lines("> quoted\n- item one\n- item two is long enough to wrap around", nil, 22, {})
	got := plain(lines)
	testing.expect(t, strings.has_prefix(got[0], "▎ "), got[0])
	testing.expect(t, strings.contains(got[1], "item one"))
	// The wrapped part of an item sits under its text.
	last := got[len(got) - 1]
	testing.expect(t, strings.has_prefix(last, "  "), last)
	for g in got {
		testing.expectf(t, tui.string_width(g) <= 22, "%q is too wide", g)
	}
}

@(test)
test_styled_code_block :: proc(t: ^testing.T) {
	lines := styled_lines("```\nx := 1\n```", nil, 40, {})
	found := false
	for line in lines {
		for s in line {
			if strings.contains(s.text, "x := 1") {
				found = s.style.bg == theme.code.bg
			}
		}
	}
	testing.expect(t, found)
}

@(test)
test_styled_mentions :: proc(t: ^testing.T) {
	shown := "hi @anna and @me"
	spans := []richtext.Mention_Span{{3, 8, false}, {13, 16, true}}
	lines := styled_lines(shown, spans, 40, {})
	testing.expect_value(t, plain(lines)[0], shown)
	for s in lines[0] {
		if s.text == "@anna" {
			testing.expect(t, s.style == theme.mention)
		}
		if s.text == "@me" {
			testing.expect(t, s.style == theme.mention_me)
		}
	}
}

@(test)
test_styled_empty_and_wide :: proc(t: ^testing.T) {
	testing.expect_value(t, len(styled_lines("", nil, 20, {})), 1)
	lines := styled_lines("日本語日本語日本語", nil, 6, {})
	for g in plain(lines) {
		testing.expect(t, tui.string_width(g) <= 6)
	}
}
