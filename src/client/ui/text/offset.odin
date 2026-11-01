package text

import "core:unicode/utf8"
import mu "vendor:microui"

// offset_at is the position in text[start:end] nearest to `x` pixels from its
// start. (The chat's version, which also measures rich text, is in
// ui/select.odin.)
offset_at :: proc(ctx: ^mu.Context, font: mu.Font, text: string, start, end: int, x: i32) -> int {
	// Each character's edges are where the text up to that character ends, as
	// select_line paints them. Adding up the characters' own widths instead
	// would also add up their rounding and end up further left the longer the
	// line is.
	left: i32
	for ch, i in text[start:end] {
		next := start + i + utf8.rune_size(ch)
		right := ctx.text_width(font, text[start:next])
		if x < (left + right) / 2 {
			return start + i
		}
		left = right
	}
	return end
}
