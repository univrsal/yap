package text

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import mu "vendor:microui"

// Wrapping text into lines, as the chat wraps messages and a text area wraps
// what is typed in it. Only the font's measurements are needed (the context's
// text_width).

// wrap_line returns the first line of `text` wrapped at `width`, as the chat
// wraps it: text[:end] is drawn, and the next line starts at `next`
// (after the newline or the spaces it broke at).
wrap_line :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> (end, next: int) {
	end = line_end(ctx, font, text, width)
	return end, len(text) - len(next_line(text, end))
}

// line_end is how much of `text` fits in `width`: up to the first
// newline if that fits, otherwise up to the last space that fits, or as many
// characters as fit if the first word doesn't (but always at least one
// character, unless the line is empty).
line_end :: proc(ctx: ^mu.Context, font: mu.Font, text: string, width: i32) -> int {
	last_space := -1
	fit := 0
	w: i32
	for ch, i in text {
		if ch == '\n' {
			return i
		}
		size := utf8.rune_size(ch)
		w += ctx.text_width(font, text[i:][:size])
		if w > width && fit > 0 {
			return last_space if last_space > 0 else fit
		}
		fit = i + size
		if ch == ' ' {
			last_space = i
		}
	}
	return len(text)
}

// next_line is what is left of `text` after a line of it that ended at
// `end` (see line_end): after the newline that ended it, or after the spaces it
// was wrapped at (and a newline right after them, which the wrap has
// already broken the line for). The next line's indentation stays.
next_line :: proc(text: string, end: int) -> string {
	rest := text[end:]
	if strings.has_prefix(rest, "\n") {
		return rest[1:]
	}
	rest = strings.trim_left_proc(
		rest,
		proc(r: rune) -> bool {return r != '\n' && unicode.is_space(r)},
	)
	return strings.trim_prefix(rest, "\n")
}
