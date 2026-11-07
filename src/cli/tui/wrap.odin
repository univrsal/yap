package tui

// Line is a range of bytes of a text, one line as it is drawn.
Line :: struct {
	start, end: int,
}

// wrap breaks `text` into the lines drawn in `width` cells and appends them to
// `lines`. A newline ends a line, and so does the width: at the last space
// that fits, or inside a word that is longer than the width. The space or newline
// a line is broken at belongs to no line. Every line has at least one rune,
// except those of empty paragraphs, and a rune wider than the width gets a line to
// itself. With a `width` of 0 or less nothing is wrapped but at newlines.
wrap :: proc(text: string, width: int, lines: ^[dynamic]Line) {
	start := 0
	for start <= len(text) {
		nl := len(text)
		for i in start ..< len(text) {
			if text[i] == '\n' {
				nl = i
				break
			}
		}
		wrap_paragraph(text, start, nl, width, lines)
		start = nl + 1
	}
}

@(private = "file")
wrap_paragraph :: proc(text: string, start, end, width: int, lines: ^[dynamic]Line) {
	if width <= 0 || start == end {
		append(lines, Line{start, end})
		return
	}
	line_start := start
	w := 0 // cells in the line so far
	last_space := -1 // byte position of the last space in the line
	i := start
	for i < end {
		r, size := decode(text, i)
		rw := rune_width(r)
		if w + rw > width {
			if r == ' ' {
				// The break is right here.
				append(lines, Line{line_start, i})
				line_start = i + 1
				i = line_start
			} else if last_space > line_start {
				append(lines, Line{line_start, last_space})
				line_start = last_space + 1
				i = line_start
			} else if i > line_start {
				append(lines, Line{line_start, i})
				line_start = i
			} else {
				// One rune that doesn't fit by itself.
				append(lines, Line{line_start, i + size})
				line_start = i + size
				i = line_start
			}
			w, last_space = 0, -1
			continue
		}
		if r == ' ' {
			last_space = i
		}
		w += rw
		i += size
	}
	if line_start < end {
		append(lines, Line{line_start, end})
	}
}
