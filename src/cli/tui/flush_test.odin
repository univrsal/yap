package tui

import "core:strconv"
import "core:strings"
import "core:testing"

// A terminal of the smallest kind: it knows the cursor, clearing the screen and
// printing, which are all render_diff writes besides styles.
@(private = "file")
Fake_Terminal :: struct {
	screen: Buffer,
	x, y:   int,
	// Styles seen, to check them without parsing them all.
	sgr:    [dynamic]string,
}

@(private = "file")
fake_play :: proc(ft: ^Fake_Terminal, data: string) {
	i := 0
	for i < len(data) {
		if data[i] == 0x1b {
			// CSI params final
			j := i + 2
			for j < len(data) && (data[j] < 0x40 || data[j] > 0x7e) {
				j += 1
			}
			params := data[i + 2:j]
			switch data[j] {
			case 'H':
				parts := strings.split(params, ";", context.temp_allocator)
				row, _ := strconv.parse_int(parts[0])
				col, _ := strconv.parse_int(parts[1])
				ft.y, ft.x = row - 1, col - 1
			case 'J':
				buffer_clear(&ft.screen)
			case 'm':
				append(&ft.sgr, strings.clone(params, context.temp_allocator))
			}
			i = j + 1
			continue
		}
		for r in data[i:] {
			if r == 0x1b {
				break
			}
			w := rune_width(r)
			// What the terminal draws is the current style; the tests only look at runes.
			set_cell(&ft.screen, ft.x, ft.y, r, w, {})
			ft.x += w
			i += first_rune_size(data[i:])
		}
	}
}

@(private = "file")
same_runes :: proc(a, b: ^Buffer) -> bool {
	if a.w != b.w || a.h != b.h {
		return false
	}
	for i in 0 ..< len(a.cells) {
		if a.cells[i].r != b.cells[i].r || a.cells[i].width != b.cells[i].width {
			return false
		}
	}
	return true
}

@(test)
test_first_render_draws_everything :: proc(t: ^testing.T) {
	cur := buffer_make(8, 3)
	defer buffer_destroy(&cur)
	put_string(&cur, 1, 0, "hi", {})
	put_string(&cur, 0, 2, "日本", {})

	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)

	ft := Fake_Terminal {
		screen = buffer_make(8, 3),
	}
	defer buffer_destroy(&ft.screen)
	defer delete(ft.sgr)
	fake_play(&ft, strings.to_string(out))
	testing.expect(t, same_runes(&ft.screen, &cur))
}

@(test)
test_unchanged_screen_writes_nothing_but_the_reset :: proc(t: ^testing.T) {
	a := buffer_make(8, 3)
	b := buffer_make(8, 3)
	defer buffer_destroy(&a)
	defer buffer_destroy(&b)
	put_string(&a, 0, 0, "same", {})
	put_string(&b, 0, 0, "same", {})
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, &a, &b)
	testing.expect_value(t, strings.to_string(out), "\x1b[0m")
}

@(test)
test_diff_only_writes_what_changed :: proc(t: ^testing.T) {
	prev := buffer_make(20, 2)
	cur := buffer_make(20, 2)
	defer buffer_destroy(&prev)
	defer buffer_destroy(&cur)
	put_string(&prev, 0, 0, "hello world", {})
	put_string(&cur, 0, 0, "hello there", {})
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, &prev, &cur)
	s := strings.to_string(out)
	// "hello " is the same, so it begins at the 't' (column 7).
	testing.expect(t, strings.has_prefix(s, "\x1b[1;7H"), s)
	testing.expect(t, strings.contains(s, "there"), s)
	testing.expect(t, !strings.contains(s, "hello"), s)
}

// Whatever the two screens are, drawing the diff over the first gives the second.
@(test)
test_diff_turns_one_screen_into_the_other :: proc(t: ^testing.T) {
	texts := [?][3]string {
		{"hello", "wor日ld", "x"},
		{"hello", "wor日ld", "x"},
		{"hel日o", "world", ""},
		{"日日日", "a", "日日"},
		{"", "", ""},
		{"abcdefgh", "😀😀😀", "end"},
		{"ab", "😀x😀", "日a"},
	}
	for i in 0 ..< len(texts) - 1 {
		prev := buffer_make(8, 3)
		cur := buffer_make(8, 3)
		defer buffer_destroy(&prev)
		defer buffer_destroy(&cur)
		for line, y in texts[i] {
			put_string(&prev, 0, y, line, {})
		}
		for line, y in texts[i + 1] {
			put_string(&cur, 0, y, line, {})
		}
		ft := Fake_Terminal {
			screen = buffer_make(8, 3),
		}
		defer buffer_destroy(&ft.screen)
		defer delete(ft.sgr)
		// The terminal shows `prev` first.
		first: strings.Builder
		defer strings.builder_destroy(&first)
		render_diff(&first, nil, &prev)
		fake_play(&ft, strings.to_string(first))
		testing.expectf(t, same_runes(&ft.screen, &prev), "step %d: first draw", i)

		out: strings.Builder
		defer strings.builder_destroy(&out)
		render_diff(&out, &prev, &cur)
		fake_play(&ft, strings.to_string(out))
		testing.expectf(t, same_runes(&ft.screen, &cur), "step %d: diff", i)
	}
}

@(test)
test_a_new_size_redraws_everything :: proc(t: ^testing.T) {
	prev := buffer_make(4, 2)
	cur := buffer_make(6, 2)
	defer buffer_destroy(&prev)
	defer buffer_destroy(&cur)
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, &prev, &cur)
	testing.expect(t, strings.contains(strings.to_string(out), "\x1b[2J"))
}

@(test)
test_styles_are_written_when_they_change :: proc(t: ^testing.T) {
	cur := buffer_make(6, 1)
	defer buffer_destroy(&cur)
	put_string(&cur, 0, 0, "ab", {fg = color_index(1), attrs = {.Bold}})
	put_string(&cur, 2, 0, "cd", {bg = color_rgb(1, 2, 3)})
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)
	s := strings.to_string(out)
	testing.expect(t, strings.contains(s, "\x1b[0;1;38;5;1mab"), s)
	testing.expect(t, strings.contains(s, "\x1b[0;48;2;1;2;3mcd"), s)
	// Not repeated for each rune.
	testing.expect_value(t, strings.count(s, "38;5;1"), 1)
}

@(test)
test_a_cell_after_an_emoji_is_placed_on_its_own :: proc(t: ^testing.T) {
	// Terminals disagree on the width of some emoji; if the cursor were left to
	// move on by itself, the rest of the row would shift where they differ.
	cur := buffer_make(8, 1)
	defer buffer_destroy(&cur)
	put_string(&cur, 0, 0, "a🍞bc", {})
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)
	text := strings.to_string(out)
	testing.expect(t, strings.contains(text, "🍞\x1b[1;4Hb"), text)
	testing.expect(t, !strings.contains(text, "ab"), text) // plain text still runs on
}

@(test)
test_symbols_can_be_sent_in_text_style :: proc(t: ^testing.T) {
	cur := buffer_make(8, 1)
	defer buffer_destroy(&cur)
	put_string(&cur, 0, 0, "a☂b", {})
	text_presentation = proc(r: rune) -> bool {return r == '☂'}
	defer text_presentation = nil
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)
	testing.expect(t, strings.contains(strings.to_string(out), "☂︎"))
}

@(test)
test_symbols_can_be_wide_emoji :: proc(t: ^testing.T) {
	wide_symbols = proc(r: rune) -> bool {return r == '☂'}
	defer wide_symbols = nil
	testing.expect_value(t, rune_width('☂'), 2)
	testing.expect_value(t, rune_width('☀'), 1)
	cur := buffer_make(8, 1)
	defer buffer_destroy(&cur)
	put_string(&cur, 0, 0, "a☂b", {})
	testing.expect_value(t, string_width("a☂b"), 4)
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)
	text := strings.to_string(out)
	testing.expect(t, strings.contains(text, "☂️"), text)
	testing.expect(t, strings.contains(text, "\x1b[1;4Hb"), text) // b is in the fourth column
}

@(test)
test_runes_the_multiplexer_counts_differently_are_drawn_as_a_mark :: proc(t: ^testing.T) {
	stand_in = proc(r: rune) -> bool {return r == '🕴'}
	defer stand_in = nil
	cur := buffer_make(8, 1)
	defer buffer_destroy(&cur)
	put_string(&cur, 0, 0, "a🕴b", {})
	out: strings.Builder
	defer strings.builder_destroy(&out)
	render_diff(&out, nil, &cur)
	text := strings.to_string(out)
	testing.expect(t, strings.contains(text, "a▫b"), text)
	testing.expect(t, !strings.contains(text, "🕴"), text)
	// The screen itself keeps the emoji (for copying).
	testing.expect_value(t, buffer_row_text(&cur, 0), "a🕴b")
}
