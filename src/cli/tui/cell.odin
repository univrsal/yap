package tui

import "core:slice"
import "core:unicode/utf8"

// What the screen is drawn into: a grid of cells, which flush.odin turns into
// the escape sequences that bring the terminal from one grid to the next.

Color_Kind :: enum u8 {
	Default, // the terminal's own
	Index, // 0 to 255 of the terminal's palette
	RGB,
}

Color :: struct {
	kind:    Color_Kind,
	r, g, b: u8, // an Index is in r
}

color_index :: proc "contextless" (i: u8) -> Color {
	return {kind = .Index, r = i}
}

color_rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return {kind = .RGB, r = r, g = g, b = b}
}

Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
	Strike,
}

Attrs :: bit_set[Attr;u8]

Style :: struct {
	fg, bg: Color,
	attrs:  Attrs,
}

// A cell holds one rune. A wide rune takes two cells: the first has width 2 and
// the rune, the second has width 0 and is only a place holder.
Cell :: struct {
	r:     rune,
	width: u8,
	style: Style,
}

blank_cell :: proc(style := Style{}) -> Cell {
	return {r = ' ', width = 1, style = style}
}

Rect :: struct {
	x, y, w, h: int,
}

rect_contains :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

Buffer :: struct {
	w, h:  int,
	cells: []Cell,
}

buffer_make :: proc(w, h: int) -> Buffer {
	b: Buffer
	buffer_resize(&b, w, h)
	return b
}

buffer_destroy :: proc(b: ^Buffer) {
	delete(b.cells)
	b^ = {}
}

// buffer_resize changes the size, and blanks the buffer.
buffer_resize :: proc(b: ^Buffer, w, h: int) {
	delete(b.cells)
	b.w, b.h = max(w, 0), max(h, 0)
	b.cells = make([]Cell, b.w * b.h)
	buffer_clear(b)
}

buffer_clear :: proc(b: ^Buffer, style := Style{}) {
	slice.fill(b.cells, blank_cell(style))
}

buffer_copy :: proc(dst, src: ^Buffer) {
	if dst.w != src.w || dst.h != src.h {
		buffer_resize(dst, src.w, src.h)
	}
	copy(dst.cells, src.cells)
}

// cell_at is the cell at x, y, which must be inside.
cell_at :: proc(b: ^Buffer, x, y: int) -> Cell {
	return b.cells[y * b.w + x]
}

// set_cell puts a rune of `width` (1 or 2) at x, y, if it fits inside the
// buffer; a wide rune whose second cell would fall outside is not drawn.
// Overwriting half of a wide rune blanks the other half.
set_cell :: proc(b: ^Buffer, x, y: int, r: rune, width: int, style: Style) {
	if x < 0 || y < 0 || x >= b.w || y >= b.h || x + width > b.w {
		return
	}
	row := b.cells[y * b.w:][:b.w]
	// Whatever wide rune the new one cuts in two.
	if row[x].width == 0 && x > 0 {
		row[x - 1] = blank_cell(row[x - 1].style)
	}
	if row[x].width == 2 {
		row[x + 1] = blank_cell(row[x + 1].style)
	}
	if width == 2 {
		if x + 2 < b.w && row[x + 1].width == 2 {
			row[x + 2] = blank_cell(row[x + 2].style)
		}
		row[x + 1] = {
			r     = 0,
			width = 0,
			style = style,
		}
	}
	row[x] = {
		r     = r,
		width = u8(width),
		style = style,
	}
}

// put_string draws `s` from x, y on, stopping at `max_x` (exclusive, default the
// right edge), and returns the x after it. Runes without width are left out. What
// is left of x = 0 is skipped, so a string can be drawn scrolled.
put_string :: proc(b: ^Buffer, x, y: int, s: string, style: Style, max_x := -1) -> int {
	if y < 0 || y >= b.h {
		return x
	}
	limit := b.w if max_x < 0 else min(max_x, b.w)
	x := x
	for r in s {
		w := rune_width(r)
		if w == 0 {
			continue
		}
		if x + w > limit {
			break
		}
		if x < 0 {
			// Cut by the left edge: a wide rune only half in leaves a blank.
			if x + w > 0 {
				set_cell(b, 0, y, ' ', 1, style)
			}
			x += w
			continue
		}
		set_cell(b, x, y, r, w, style)
		x += w
	}
	return x
}

// fill draws `r` (a narrow one) over a rectangle, clipped to the buffer.
fill :: proc(b: ^Buffer, rect: Rect, style: Style, r := ' ') {
	for y in max(rect.y, 0) ..< min(rect.y + rect.h, b.h) {
		for x in max(rect.x, 0) ..< min(rect.x + rect.w, b.w) {
			set_cell(b, x, y, r, 1, style)
		}
	}
}

// buffer_row_text is a row as text (for tests and for copying): wide runes once,
// trailing blanks cut.
buffer_row_text :: proc(b: ^Buffer, y: int, allocator := context.temp_allocator) -> string {
	out := make([dynamic]u8, allocator)
	for x in 0 ..< b.w {
		c := cell_at(b, x, y)
		if c.width == 0 {
			continue
		}
		append_rune(&out, c.r)
	}
	n := len(out)
	for n > 0 && out[n - 1] == ' ' {
		n -= 1
	}
	return string(out[:n])
}

@(private)
append_rune :: proc(out: ^[dynamic]u8, r: rune) {
	buf, n := utf8.encode_rune(r)
	append(out, ..buf[:n])
}
