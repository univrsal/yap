package tui

import "core:fmt"
import "core:strings"

// render_diff writes the escape sequences that make a terminal that shows `prev`
// show `cur` instead, to `out`. With no `prev` (or one of another size) it
// clears the screen and draws everything. The cursor is left wherever the
// last write ended; the caller puts it where it belongs.
render_diff :: proc(out: ^strings.Builder, prev: ^Buffer, cur: ^Buffer) {
	full := prev == nil || prev.w != cur.w || prev.h != cur.h
	if full {
		strings.write_string(out, "\x1b[0m\x1b[2J")
	}
	cx, cy := -1, -1 // where the cursor is, if known
	style: Style
	style_known := false
	if full {
		style_known = true // reset above
	}
	for y in 0 ..< cur.h {
		for x in 0 ..< cur.w {
			c := cell_at(cur, x, y)
			if c.width == 0 {
				continue
			}
			if !full && cell_at(prev, x, y) == c {
				continue
			}
			if full && c == blank_cell() {
				continue // the cleared screen already has it
			}
			if cx != x || cy != y {
				fmt.sbprintf(out, "\x1b[%d;%dH", y + 1, x + 1)
			}
			if !style_known || style != c.style {
				write_style(out, c.style)
				style, style_known = c.style, true
			}
			strings.write_rune(out, c.r)
			cx, cy = x + int(c.width), y
		}
	}
	strings.write_string(out, "\x1b[0m")
}

@(private)
write_style :: proc(out: ^strings.Builder, s: Style) {
	strings.write_string(out, "\x1b[0")
	for a in s.attrs {
		switch a {
		case .Bold:
			strings.write_string(out, ";1")
		case .Dim:
			strings.write_string(out, ";2")
		case .Italic:
			strings.write_string(out, ";3")
		case .Underline:
			strings.write_string(out, ";4")
		case .Reverse:
			strings.write_string(out, ";7")
		case .Strike:
			strings.write_string(out, ";9")
		}
	}
	write_color(out, s.fg, 38)
	write_color(out, s.bg, 48)
	strings.write_string(out, "m")
}

@(private)
write_color :: proc(out: ^strings.Builder, c: Color, base: int) {
	switch c.kind {
	case .Default:
	case .Index:
		fmt.sbprintf(out, ";%d;5;%d", base, c.r)
	case .RGB:
		fmt.sbprintf(out, ";%d;2;%d;%d;%d", base, c.r, c.g, c.b)
	}
}
