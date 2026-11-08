package main

import "core:strings"

import "client:richtext"
import "tui"

// A piece of text with one style: the parts a line is drawn from.
Seg :: struct {
	text:  string,
	style: tui.Style,
}

// seg_width is the cells the segments take.
segs_width :: proc(segs: []Seg) -> (w: int) {
	for s in segs {
		w += tui.string_width(s.text)
	}
	return
}

// draw_segs draws segments from x, y on up to max_x (exclusive) and returns the
// x after them.
draw_segs :: proc(b: ^tui.Buffer, x, y: int, segs: []Seg, max_x := -1) -> int {
	x := x
	for s in segs {
		x = tui.put_string(b, x, y, s.text, s.style, max_x)
	}
	return x
}

// styled_lines turns a message's text as it is shown (mentions already written
// out, see richtext.mentions_display) into lines of segments at most `width`
// cells wide: markdown becomes styles, quotes get a bar, long lines are wrapped,
// and list items are wrapped under their text. Everything is allocated with
// `allocator`, which should be an arena or the temp allocator.
styled_lines :: proc(
	shown: string,
	spans: []richtext.Mention_Span,
	width: int,
	base: tui.Style,
	allocator := context.temp_allocator,
) -> [][]Seg {
	context.allocator = allocator
	atoms := make([]richtext.Md_Atom, len(spans), context.temp_allocator)
	for sp, i in spans {
		atoms[i] = {sp.start, sp.end, false}
	}
	rt := richtext.markdown_parse(shown, atoms, context.temp_allocator)

	out := make([dynamic][]Seg)
	wrapped := make([dynamic]tui.Line, context.temp_allocator)
	for line in rt.lines {
		prefix_w := 2 * line.quote
		indent := 0
		if line.kind == .Bullet || line.kind == .Number {
			indent = tui.string_width(
				rt.text[line.start:line.start + min(line.marker, line.end - line.start)],
			)
		}
		text := rt.text[line.start:line.end]
		clear(&wrapped)
		// The lines under a list item are indented, so all of them are wrapped narrower.
		tui.wrap(text, max(width - prefix_w - indent, 1), &wrapped)
		for w, i in wrapped {
			segs := make([dynamic]Seg)
			for _ in 0 ..< line.quote {
				append(&segs, Seg{"▎ ", theme.quote})
			}
			if i > 0 && indent > 0 {
				append(
					&segs,
					Seg{strings.repeat(" ", min(indent, max(width - prefix_w - 1, 0))), base},
				)
			}
			add_styled(&segs, &rt, spans, line, line.start + w.start, line.start + w.end, base)
			append(&out, segs[:])
		}
	}
	return out[:]
}

// add_styled appends the segments of rt.text[start:end], cut where the style changes.
@(private = "file")
add_styled :: proc(
	segs: ^[dynamic]Seg,
	rt: ^richtext.Rich_Text,
	spans: []richtext.Mention_Span,
	line: richtext.Md_Line,
	start, end: int,
	base: tui.Style,
) {
	piece_start := start
	current := style_at(rt, spans, line, start, base)
	for i in start ..< end {
		// Cut only at the start of a rune.
		if rt.text[i] & 0xc0 == 0x80 {
			continue
		}
		s := style_at(rt, spans, line, i, base)
		if s != current {
			append(segs, Seg{rt.text[piece_start:i], current})
			piece_start, current = i, s
		}
	}
	if piece_start < end {
		append(segs, Seg{rt.text[piece_start:end], current})
	}
}

@(private = "file")
style_at :: proc(
	rt: ^richtext.Rich_Text,
	spans: []richtext.Mention_Span,
	line: richtext.Md_Line,
	pos: int,
	base: tui.Style,
) -> tui.Style {
	s := base
	if line.kind == .Code {
		s = theme.code
	}
	for run in rt.runs {
		if pos >= run.start && pos < run.end {
			if .Bold in run.styles {s.attrs += {.Bold}}
			if .Italic in run.styles {s.attrs += {.Italic}}
			if .Underline in run.styles {s.attrs += {.Underline}}
			if .Strike in run.styles {s.attrs += {.Strike}}
			if .Code in run.styles {
				s.fg, s.bg = theme.code.fg, theme.code.bg
			}
		}
	}
	for l in rt.links {
		if pos >= l.start && pos < l.end {
			s.fg, s.attrs = theme.link.fg, s.attrs + theme.link.attrs
		}
	}
	for a, i in rt.atoms {
		if a.start >= 0 && pos >= a.start && pos < a.end && i < len(spans) {
			if a.url {
				s.fg, s.attrs = theme.link.fg, s.attrs + theme.link.attrs
			} else {
				s = theme.mention_me if spans[i].me else theme.mention
			}
		}
	}
	return s
}
