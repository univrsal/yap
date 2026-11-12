package richtext

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "client:platform"

// A message's text as written, which can have several lines and markdown. The
// timeline shows the lines as they are and the markdown as styles. Where a
// message is shown on a single line (the line of a reply, a link to it, pins,
// search results, notifications), markdown_plain removes the markers and
// one_line joins the lines.
//
// The markdown is a chat flavour that is close to Discord's:
//
//   **bold**  *italic*  _italic_  __underline__  ~~strike~~  `code`
//   ```                 a code block, up to the closing fence or the end
//   > quote             (> > nests)
//   - item, * item      a bullet, shown as a bullet character
//   1. item             a numbered item, as written
//   # Heading           a heading, # to ###### for levels 1 to 6 (closing #
//                       after a space are dropped)
//   | a | b |           a table: a row of column names, then a row of dashes
//   |---|:-:|           for each column (a colon on the side it is aligned
//   | 1 | 2 |           to, both for the middle), then rows with a | in them.
//                       Cells are separated by a tab in the text.
//   [text](url)         a link that shows `text` and goes to a web address
//   ![alt](url)         a picture (as Mattermost and GitHub write them), shown
//                       as a link to it that shows `alt`; a size (`=44x22`)
//                       and a title (`"title"`) after the address are dropped.
//                       Pictures aren't fetched: a client never goes to an
//                       address on its own. Inside a link's text
//                       (`[![alt](img) text](url)`) a picture is just its `alt`.
//   \*                  a marker that is just the character
//
// markdown_parse works on a message as it is shown (see text_display_links), so
// mentions, the server's emoji and links to messages are already replaced by
// names and placeholders. They are passed in as atoms, together with the web
// addresses found in the text, and are never looked into. That way
// `@foo_bar_baz` and `https://x.org/a_b_c` stay as they are. Each atom ends up
// at its new position in the text without the markers, or at -1 if it was
// removed (the address of a [text](url) link).
//
// To keep ordinary text from accidentally turning into markup, these rules
// apply:
//   - A marker opens only before something that isn't a space and closes only
//     after something that isn't a space: `a * b` is plain text.
//   - `_` doesn't open or close inside a word (`snake_case_name`), and `*`
//     doesn't between two digits (`2*3*4`).
//   - A marker that isn't closed on its line is just the character.
//   - Blocks are handled line by line, and styles don't continue past the end
//     of a line.
//   - Nothing in code (a span or a block) is markup.

// one_line returns `text` with its newlines replaced by spaces. The result has
// the same length, so spans into `text` still fit it. It is only allocated (with
// `allocator`) if the text has any newlines.
one_line :: proc(text: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(text, '\n') < 0 {
		return text
	}
	out, _ := strings.replace_all(text, "\n", " ", allocator)
	return out
}

Md_Style :: enum u8 {
	Bold,
	Italic,
	Underline,
	Strike,
	Code, // monospace font with a background, unless the line is part of a code block
}
Md_Styles :: bit_set[Md_Style;u8]

// A stretch of the text that has one set of styles. The runs of a Rich_Text
// cover its text in order.
Md_Run :: struct {
	start, end: int,
	styles:     Md_Styles,
}

Md_Line_Kind :: enum u8 {
	Plain,
	Code, // a line of a code block
	Bullet, // a list item whose text starts with its indent and "• "
	Number, // a numbered list item whose text starts with its indent and "1. "
	Heading, // a heading, of `level` 1 to 6
	Table_Head, // the first row of a table: its column names
	Table_Row, // a row of a table after the first
}

// One line of the text as it is in the message. Wrapping is left to the
// renderer.
Md_Line :: struct {
	start, end: int, // the line's text, without its newline
	kind:       Md_Line_Kind,
	quote:      int, // how many levels deep the quote is; 0 if it isn't quoted
	marker:     int, // the length in bytes of a list item's indent and marker, counted from `start`; wrapped lines are indented to this position
	level:      int, // .Heading: 1 for #, up to 6 for ######
	// A table's row: which of Rich_Text.tables, and its cells, one for each of
	// the table's columns, in order. The cells are separated by a tab, so a
	// copied table can be pasted into a spreadsheet.
	table:      int,
	cells:      []Md_Cell,
}

// A cell of a table's row: where its text is.
Md_Cell :: struct {
	start, end: int,
}

Md_Align :: enum u8 {
	Left,
	Center,
	Right,
}

// A table: its columns' alignment, one for each column. Its rows are the lines
// that refer to it.
Md_Table :: struct {
	align: []Md_Align,
}

// A [text](url) link: the position of its text and the address it goes to.
Md_Link :: struct {
	start, end: int,
	url:        string,
}

// Something in the text that the parser doesn't look into: a mention, one of
// the server's emoji, a link to a message, or a web address (`url`, which is
// what a [text](url) link may point at).
Md_Atom :: struct {
	start, end: int,
	url:        bool,
}

Rich_Text :: struct {
	text:   string, // the text that is drawn, without the markers
	runs:   []Md_Run,
	lines:  []Md_Line,
	links:  []Md_Link,
	atoms:  []Md_Atom, // the atoms that were passed in, at their positions in `text`; -1 if the atom was removed
	tables: []Md_Table,
}

// markdown_parse returns `shown` with its markdown worked out. `atoms` are byte
// ranges of `shown` that must not be looked into (see above). They can be in
// any order but must not overlap. Everything is allocated with `allocator`.
markdown_parse :: proc(
	shown: string,
	atoms: []Md_Atom,
	allocator := context.temp_allocator,
) -> Rich_Text {
	o := Out {
		b     = strings.builder_make(allocator),
		segs  = make([dynamic]Seg, context.temp_allocator),
		runs  = make([dynamic]Md_Run, allocator),
		links = make([dynamic]Md_Link, allocator),
	}
	p := Parser {
		src   = shown,
		atoms = atoms,
		at    = make(map[int]int, len(atoms), context.temp_allocator),
		out   = &o,
	}
	for a, i in atoms {
		p.at[a.start] = i
	}
	lines := make([dynamic]Md_Line, allocator)
	tables := make([dynamic]Md_Table, allocator)

	// The lines of the source, as a table looks at the line after its first.
	Src_Line :: struct {
		start, end: int,
	}
	src_lines := make([dynamic]Src_Line, context.temp_allocator)
	{
		rest := shown
		ls := 0
		for line in strings.split_lines_iterator(&rest) {
			append(&src_lines, Src_Line{ls, ls + len(line)})
			ls += len(line) + 1
		}
	}

	in_fence := false
	for k := 0; k < len(src_lines); k += 1 {
		start := src_lines[k].start
		line := shown[start:src_lines[k].end]
		trimmed := strings.trim_left(line, " ")
		fence := strings.has_prefix(trimmed, "```")
		if in_fence {
			if fence {
				in_fence = false
				continue
			}
			l := line_begin(&o, lines[:], true)
			out_copy(&o, shown, start, start + len(line), {.Code})
			append(&lines, Md_Line{start = l, end = out_len(&o), kind = .Code})
			continue
		}
		// A fence opens a block, unless it is closed again on the same line
		// (```x```), in which case it is a code span. A single word after the
		// fence is the block's language, and anything longer is its first line.
		if fence && !strings.contains(trimmed[3:], "```") {
			in_fence = true
			after := strings.trim_left_space(trimmed[3:])
			if strings.contains_any(strings.trim_right_space(after), " \t") {
				first := start + len(line) - len(after)
				l := line_begin(&o, lines[:], true)
				out_copy(&o, shown, first, first + len(after), {.Code})
				append(&lines, Md_Line{start = l, end = out_len(&o), kind = .Code})
			}
			continue
		}

		ml := Md_Line {
			start = line_begin(&o, lines[:]),
		}
		end := start + len(line)
		body: int
		body, ml.quote = quoted(shown, start, end)

		// A table: a row of column names, then a row that says how each column
		// is aligned (|---|:--:|), with as many columns, and then the rows that
		// follow with the same quote and a | in them.
		if k + 1 < len(src_lines) && strings.index_byte(shown[body:end], '|') >= 0 {
			next := src_lines[k + 1]
			next_body, next_quote := quoted(shown, next.start, next.end)
			head := table_split(&p, body, end)
			align, is_table := table_align(shown[next_body:next.end])
			if is_table && next_quote == ml.quote && len(align) == len(head) {
				ml.kind, ml.table = .Table_Head, len(tables)
				append(&tables, Md_Table{slice.clone(align, allocator)})
				ml.cells = table_row(&p, head, len(align), allocator)
				ml.end = out_len(&o)
				out_bold(&o, ml.start)
				append(&lines, ml)
				k += 1
				for k + 1 < len(src_lines) {
					row := src_lines[k + 1]
					row_body, row_quote := quoted(shown, row.start, row.end)
					if row_quote != ml.quote ||
					   strings.index_byte(shown[row_body:row.end], '|') < 0 {
						break
					}
					k += 1
					rl := Md_Line {
						start = line_begin(&o, lines[:]),
						kind  = .Table_Row,
						quote = ml.quote,
						table = ml.table,
					}
					rl.cells = table_row(
						&p,
						table_split(&p, row_body, row.end),
						len(align),
						allocator,
					)
					rl.end = out_len(&o)
					append(&lines, rl)
				}
				continue
			}
		}

		// A heading: one to six #, a space and its text, which may be followed
		// by a space and more # that aren't part of it.
		hashes := 0
		for body + hashes < end && hashes < 7 && shown[body + hashes] == '#' {
			hashes += 1
		}
		if hashes >= 1 && hashes <= 6 && body + hashes < end && shown[body + hashes] == ' ' {
			text_start := body + hashes + 1
			text_end := end
			for text_end > text_start && shown[text_end - 1] == ' ' {
				text_end -= 1
			}
			closing := text_end
			for closing > text_start && shown[closing - 1] == '#' {
				closing -= 1
			}
			if closing < text_end && (closing == text_start || shown[closing - 1] == ' ') {
				text_end = closing
				for text_end > text_start && shown[text_end - 1] == ' ' {
					text_end -= 1
				}
			}
			for text_start < text_end && shown[text_start] == ' ' {
				text_start += 1
			}
			if text_start < text_end {
				ml.kind, ml.level = .Heading, hashes
				inline(&p, text_start, text_end)
				ml.end = out_len(&o)
				out_bold(&o, ml.start)
				append(&lines, ml)
				continue
			}
		}

		// A list item consists of its indent, followed by "- ", "* " or "1. ".
		indent := body
		for indent < end && shown[indent] == ' ' {
			indent += 1
		}
		item := shown[indent:end]
		digits := 0
		for digits < len(item) && digits < 9 && item[digits] >= '0' && item[digits] <= '9' {
			digits += 1
		}
		switch {
		case strings.has_prefix(item, "- "), strings.has_prefix(item, "* "):
			ml.kind = .Bullet
			out_copy(&o, shown, body, indent, {})
			out_put(&o, "• ", {})
			ml.marker = out_len(&o) - ml.start
			body = indent + 2
		case digits > 0 && strings.has_prefix(item[digits:], ". "):
			ml.kind = .Number
			out_copy(&o, shown, body, indent + digits + 2, {})
			ml.marker = out_len(&o) - ml.start
			body = indent + digits + 2
		}
		inline(&p, body, end)
		ml.end = out_len(&o)
		append(&lines, ml)
	}
	if len(lines) == 0 {
		append(&lines, Md_Line{})
	}

	text := strings.to_string(o.b)
	moved := make([]Md_Atom, len(atoms), allocator)
	for a, i in atoms {
		moved[i] = {-1, -1, a.url}
		// The segments are in the order of the source and don't overlap, so the
		// one that holds the atom's start is the last that starts at or
		// before it (not a search through all of them for every atom: a message
		// of 60 000 bytes can have 10 000 of both).
		lo, hi := 0, len(o.segs)
		for lo < hi {
			mid := lo + (hi - lo) / 2
			if o.segs[mid].src <= a.start {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			s := o.segs[lo - 1]
			if a.end <= s.src + s.n {
				moved[i].start = s.out + a.start - s.src
				moved[i].end = s.out + a.end - s.src
			}
		}
	}
	return {text, o.runs[:], lines[:], o.links[:], moved, tables[:]}
}

// markdown_plain returns a message as shown (see mentions_display and
// text_display) on a single line with its markdown removed. It is meant for
// places where a message is summarized in one line. The result is allocated in
// the temp allocator. A table's cells are separated by " | ".
markdown_plain :: proc(shown: string) -> string {
	if !strings.contains_any(shown, "*_~`>[\\-0123456789#|") {
		return one_line(shown)
	}
	links := platform.find_links(shown)
	atoms := make([]Md_Atom, len(links), context.temp_allocator)
	for l, i in links {
		atoms[i] = {l.start, l.end, true}
	}
	rt := markdown_parse(shown, atoms)
	text := rt.text
	if len(rt.tables) > 0 {
		text, _ = strings.replace_all(text, "\t", " | ", context.temp_allocator)
	}
	return one_line(text)
}

// markdown_toggle puts `marker` (`**`, `*`, `__`, `~~` or a backtick) around
// text[lo:hi], the selection in a composer, or removes it if it is already
// there, either just outside the selection or at both ends of it. With nothing
// selected it inserts a pair so the user can type between them. It returns where
// the selection is afterwards. The result is allocated in the temp allocator.
//
// `*` is both italic and half of bold. A run of them counts as italic when its
// length is odd (`*`, `***`) and as bold when it is two or more, so italic and
// bold can be switched on and off separately.
markdown_toggle :: proc(
	text: string,
	lo, hi: int,
	marker: string,
) -> (
	out: string,
	new_lo, new_hi: int,
) {
	m := len(marker)
	c := marker[0]
	there :: proc(c: u8, m, left, right: int) -> bool {
		if c == '*' && m == 1 {
			return left % 2 == 1 && right % 2 == 1
		}
		return left >= m && right >= m
	}
	run_back :: proc(s: string, from: int, c: u8) -> int {
		n := 0
		for from - n > 0 && s[from - n - 1] == c {
			n += 1
		}
		return n
	}
	run_on :: proc(s: string, from: int, c: u8) -> int {
		n := 0
		for from + n < len(s) && s[from + n] == c {
			n += 1
		}
		return n
	}
	sel := text[lo:hi]
	switch {
	case there(c, m, run_back(text, lo, c), run_on(text, hi, c)):
		out = strings.concatenate({text[:lo - m], sel, text[hi + m:]}, context.temp_allocator)
		return out, lo - m, hi - m
	case len(sel) >= 2 * m &&
	     there(c, m, run_on(sel, 0, c), run_back(sel, len(sel), c)) &&
	     run_on(sel, 0, c) < len(sel):
		out = strings.concatenate(
			{text[:lo], sel[m:len(sel) - m], text[hi:]},
			context.temp_allocator,
		)
		return out, lo, hi - 2 * m
	}
	out = strings.concatenate({text[:lo], marker, sel, marker, text[hi:]}, context.temp_allocator)
	return out, lo + m, hi + m
}

// The output written so far, and where it came from.
@(private = "file")
Out :: struct {
	b:     strings.Builder,
	// Stretches copied unchanged from the source, which is where atoms ended up.
	segs:  [dynamic]Seg,
	runs:  [dynamic]Md_Run,
	links: [dynamic]Md_Link,
}

@(private = "file")
Seg :: struct {
	src, out, n: int,
}

@(private = "file")
out_len :: proc(o: ^Out) -> int {
	return strings.builder_len(o.b)
}

// line_begin starts a line, which means writing a newline unless it is the
// first line. The newline between two lines of a code block is code too, so a
// code block forms one continuous run.
@(private = "file")
line_begin :: proc(o: ^Out, lines: []Md_Line, code := false) -> int {
	if len(lines) > 0 {
		out_put(o, "\n", {.Code} if code && lines[len(lines) - 1].kind == .Code else {})
	}
	return out_len(o)
}

// out_copy writes src[start:end] unchanged, in `styles`.
@(private = "file")
out_copy :: proc(o: ^Out, src: string, start, end: int, styles: Md_Styles) {
	if end <= start {
		return
	}
	at := out_len(o)
	strings.write_string(&o.b, src[start:end])
	if n := len(o.segs);
	   n > 0 &&
	   o.segs[n - 1].src + o.segs[n - 1].n == start &&
	   o.segs[n - 1].out + o.segs[n - 1].n == at {
		o.segs[n - 1].n += end - start
	} else {
		append(&o.segs, Seg{start, at, end - start})
	}
	out_run(o, at, out_len(o), styles)
}

// out_put writes text that isn't from the source (a bullet or a newline).
@(private = "file")
out_put :: proc(o: ^Out, s: string, styles: Md_Styles) {
	at := out_len(o)
	strings.write_string(&o.b, s)
	out_run(o, at, out_len(o), styles)
}

// out_bold makes what was written from `at` on bold (a heading, a table's
// column names), splitting the run that `at` is in.
@(private = "file")
out_bold :: proc(o: ^Out, at: int) {
	for i := len(o.runs) - 1; i >= 0 && o.runs[i].end > at; i -= 1 {
		r := &o.runs[i]
		if r.start < at {
			tail := Md_Run{at, r.end, r.styles + {.Bold}}
			r.end = at
			inject_at(&o.runs, i + 1, tail)
			return
		}
		r.styles += {.Bold}
	}
}

@(private = "file")
out_run :: proc(o: ^Out, start, end: int, styles: Md_Styles) {
	if end <= start {
		return
	}
	if n := len(o.runs); n > 0 && o.runs[n - 1].end == start && o.runs[n - 1].styles == styles {
		o.runs[n - 1].end = end
		return
	}
	append(&o.runs, Md_Run{start, end, styles})
}

@(private = "file")
Parser :: struct {
	src:   string,
	atoms: []Md_Atom,
	at:    map[int]int, // atoms by their start position
	out:   ^Out,
	// In a table's cell, where a \| is a | even in code (it would split the
	// cell otherwise).
	cell:  bool,
}

@(private)
Tok_Kind :: enum u8 {
	Text, // copied unchanged
	Code, // the content of a code span
	Delim, // a run of * _ or ~, minus the part that has been used up
	Link_Open, // the start and end of a [text](url) link's text
	Link_Close,
}

@(private)
Tok :: struct {
	kind:                  Tok_Kind,
	start, end:            int, // in the source
	styles:                Md_Styles,
	// Delim: its character, whether it can open or close, and how much of the
	// run was used up by closing (from the left) and by opening (from the right).
	ch:                    u8,
	can_open, can_close:   bool,
	used_left, used_right: int,
	url:                   string, // Link_Close: the address the link goes to
}

@(private)
tok_count :: proc(t: Tok) -> int {
	return t.end - t.start - t.used_left - t.used_right
}

// inline writes src[start:end], the text of one line, with its styles.
@(private = "file")
inline :: proc(p: ^Parser, start, end: int) {
	src := p.src
	toks := make([dynamic]Tok, context.temp_allocator)
	text :: proc(toks: ^[dynamic]Tok, start, end: int) {
		if n := len(toks); n > 0 && toks[n - 1].kind == .Text && toks[n - 1].end == start {
			toks[n - 1].end = end
			return
		}
		append(toks, Tok{kind = .Text, start = start, end = end})
	}
	// While inside a link's text: the position of its ] and the end of the link.
	link_close, link_end := -1, -1
	link_url := ""

	i := start
	for i < end {
		if a, ok := p.at[i]; ok && p.atoms[a].end <= end {
			text(&toks, i, p.atoms[a].end)
			i = p.atoms[a].end
			continue
		}
		if i == link_close {
			append(&toks, Tok{kind = .Link_Close, start = i, end = i, url = link_url})
			i = link_end
			link_close = -1
			continue
		}
		ch := src[i]
		switch ch {
		case '\\':
			if i + 1 < end &&
			   strings.index_byte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", src[i + 1]) >= 0 {
				text(&toks, i + 1, i + 2)
				i += 2
				continue
			}
		case '`':
			n := run_length(src, i, end)
			if close := find_backticks(p, i + n, end, n); close >= 0 {
				append(&toks, Tok{kind = .Code, start = i + n, end = close})
				i = close + n
			} else {
				text(&toks, i, i + n)
				i += n
			}
			continue
		case '!':
			if img, ok := find_image(p, i, end); ok {
				// Its words, or its title if it has none. On its own it is a link
				// to the picture, which shows the address if it has neither.
				label_start, label_end := img.alt_start, img.alt_end
				if label_start == label_end {
					label_start, label_end = img.title_start, img.title_end
				}
				if link_close >= 0 {
					if label_start < label_end {
						text(&toks, label_start, label_end)
					}
				} else {
					if label_start == label_end {
						label_start, label_end = img.url_start, img.url_end
					}
					append(&toks, Tok{kind = .Link_Open, start = i, end = i})
					text(&toks, label_start, label_end)
					append(&toks, Tok{kind = .Link_Close, start = i, end = i, url = img.url})
				}
				i = img.end
				continue
			}
		case '[':
			if link_close < 0 {
				if c, e, url, ok := find_link(p, i, end); ok {
					append(&toks, Tok{kind = .Link_Open, start = i, end = i})
					link_close, link_end, link_url = c, e, url
					i += 1
					continue
				}
			}
		case '*', '_', '~':
			n := run_length(src, i, end)
			prev := ' ' if i == start else utf8_last(src[start:i])
			next := ' ' if i + n >= end else utf8_first(src[i + n:end])
			opens := !unicode.is_space(next)
			closes := !unicode.is_space(prev)
			switch ch {
			case '_':
				opens = opens && !is_alnum(prev)
				closes = closes && !is_alnum(next)
			case '*':
				if is_digit(prev) && is_digit(next) {
					opens, closes = false, false
				}
			case '~':
				if n < 2 {
					opens, closes = false, false
				}
			}
			if opens || closes {
				append(
					&toks,
					Tok {
						kind = .Delim,
						start = i,
						end = i + n,
						ch = ch,
						can_open = opens,
						can_close = closes,
					},
				)
			} else {
				text(&toks, i, i + n)
			}
			i += n
			continue
		}
		_, size := utf8.decode_rune_in_string(src[i:end])
		text(&toks, i, i + size)
		i += size
	}

	pair_delims(toks[:])

	o := p.out
	link_start := 0
	for t in toks {
		switch t.kind {
		case .Text:
			out_copy(o, src, t.start, t.end, t.styles)
		case .Code:
			from := t.start
			if p.cell {
				for j := t.start; j + 1 < t.end; j += 1 {
					if src[j] == '\\' && src[j + 1] == '|' {
						out_copy(o, src, from, j, t.styles + {.Code})
						from = j + 1
					}
				}
			}
			out_copy(o, src, from, t.end, t.styles + {.Code})
		case .Delim:
			out_copy(o, src, t.start + t.used_left, t.end - t.used_right, t.styles)
		case .Link_Open:
			link_start = out_len(o)
		case .Link_Close:
			if out_len(o) == link_start {
				// Its text was only pictures with no words: the address shows.
				out_put(o, t.url, t.styles)
			}
			append(
				&o.links,
				Md_Link{link_start, out_len(o), strings.clone(t.url, o.b.buf.allocator)},
			)
		}
	}
}

// pair_delims matches each closing run of * _ ~ with the nearest opening run of
// the same character before it, like CommonMark does (simplified). Two
// characters are used from each run if both runs have two (bold, underline,
// strike), otherwise one (italic; strike takes two). The text between a pair
// gets its style, and runs in between that were left open stay unchanged.
//
// The time it takes is in proportion to the number of tokens (a message may
// have tens of thousands), not their square: the openers that may still be
// had wait on a stack for each character (a closer takes the nearest, and
// openers that have been used up or cut off are dropped as they are found),
// the runs between a pair are marked as unable to open once each (skipping
// those that already are), and the styles are added up from differences in
// one pass at the end. A link's boundaries clear the stacks, since pairs must
// not cross them.
@(private)
pair_delims :: proc(toks: []Tok) {
	slot_of :: proc(ch: u8) -> int {
		switch ch {
		case '*':
			return 0
		case '_':
			return 1
		}
		return 2
	}
	stacks: [3][dynamic]int
	for &stack in stacks {
		stack = make([dynamic]int, context.temp_allocator)
	}
	// diffs[style][k] is how many pairs of that style start (+) and end (-) at
	// the token k, allocated when there is a first one.
	diffs: [Md_Style][]int
	// skip[k] is the first token from k on that hasn't been marked unable to
	// open by a pair around it (union-find with path halving).
	skip := make([]int, len(toks) + 1, context.temp_allocator)
	for k in 0 ..= len(toks) {
		skip[k] = k
	}
	first_unmarked :: proc(skip: []int, k: int) -> int {
		k := k
		for skip[k] != k {
			skip[k] = skip[skip[k]]
			k = skip[k]
		}
		return k
	}

	for c in 0 ..< len(toks) {
		#partial switch toks[c].kind {
		case .Link_Open, .Link_Close:
			for &stack in stacks {
				clear(&stack)
			}
			continue
		case .Delim:
		case:
			continue
		}
		stack := &stacks[slot_of(toks[c].ch)]
		if toks[c].can_close {
			for tok_count(toks[c]) > 0 {
				// The nearest opener that still is one.
				for len(stack) > 0 {
					top := toks[stack[len(stack) - 1]]
					if top.can_open && tok_count(top) > 0 {
						break
					}
					pop(stack)
				}
				if len(stack) == 0 {
					break
				}
				o := stack[len(stack) - 1]
				two := tok_count(toks[o]) >= 2 && tok_count(toks[c]) >= 2
				n := 2 if two else 1
				style: Md_Style
				switch toks[c].ch {
				case '~':
					if !two {
						return_to_text(toks, o, c)
						continue
					}
					style = .Strike
				case '_':
					style = .Underline if two else .Italic
				case:
					style = .Bold if two else .Italic
				}
				if diffs[style] == nil {
					diffs[style] = make([]int, len(toks) + 1, context.temp_allocator)
				}
				diffs[style][o + 1] += 1
				diffs[style][c] -= 1
				// Markers that were left open in between stay unchanged.
				for k := first_unmarked(skip, o + 1); k < c; k = first_unmarked(skip, k) {
					if toks[k].kind == .Delim {
						toks[k].can_open = false
					}
					skip[k] = k + 1
				}
				toks[o].used_right += n
				toks[c].used_left += n
			}
		}
		if toks[c].can_open && tok_count(toks[c]) > 0 {
			append(stack, c)
		}
	}

	for style in Md_Style {
		if diffs[style] == nil {
			continue
		}
		covered := 0
		for k in 0 ..< len(toks) {
			covered += diffs[style][k]
			if covered > 0 {
				toks[k].styles += {style}
			}
		}
	}
}

// return_to_text gives up on an opener that can't be closed by `c` (a single
// ~), so the search continues past it.
@(private = "file")
return_to_text :: proc(toks: []Tok, o, c: int) {
	toks[o].can_open = false
}

// run_length returns how many times the character at `i` is repeated in a row.
@(private = "file")
run_length :: proc(src: string, i, end: int) -> int {
	n := 1
	for i + n < end && src[i + n] == src[i] {
		n += 1
	}
	return n
}

// find_backticks finds a run of exactly `n` backticks starting at `from`,
// outside of atoms. That is where a code span closes. It returns -1 if there is
// none.
@(private = "file")
find_backticks :: proc(p: ^Parser, from, end: int, n: int) -> int {
	j := from
	for j < end {
		if a, ok := p.at[j]; ok {
			j = p.atoms[a].end
			continue
		}
		if p.src[j] != '`' {
			j += 1
			continue
		}
		m := run_length(p.src, j, end)
		if m == n {
			return j
		}
		j += m
	}
	return -1
}

// find_link checks whether a [text](url) link starts at `i`. A link consists of
// some text, then `](`, a web address that is an atom, and `)`. It returns the
// position of the `]`, where the link ends, and the address.
@(private = "file")
find_link :: proc(p: ^Parser, i, end: int) -> (close, link_end: int, url: string, ok: bool) {
	j := i + 1
	for j < end {
		if a, found := p.at[j]; found {
			j = p.atoms[a].end
			continue
		}
		switch p.src[j] {
		case '\\':
			j += 2
			continue
		case '!':
			if img, found := find_image(p, j, end); found {
				j = img.end
				continue
			}
		case '[':
			return
		case ']':
			if j == i + 1 || j + 1 >= end || p.src[j + 1] != '(' {
				return
			}
			a, found := p.at[j + 2]
			if !found || !p.atoms[a].url {
				return
			}
			atom := p.atoms[a]
			if atom.end >= end || p.src[atom.end] != ')' {
				return
			}
			url = p.src[atom.start:atom.end]
			if len(url) >= 4 && strings.equal_fold(url[:4], "www.") {
				url = strings.concatenate({"https://", url}, context.temp_allocator)
			}
			return j, atom.end + 1, url, true
		}
		j += 1
	}
	return
}

// A picture: ![alt](url), where the address may be followed by a size
// (`=44x22`, `=44x`, `=x22`) and a title in double quotes, each after a space.
@(private = "file")
Md_Image :: struct {
	alt_start, alt_end:     int,
	url_start, url_end:     int,
	title_start, title_end: int, // empty if it has none
	url:                    string,
	end:                    int, // after its `)`
}

// find_image checks whether a picture starts at `i` (its `!`). Its words may
// be empty but can't have a `[` or `]` in them, and the address has to be a
// web address (an atom).
@(private = "file")
find_image :: proc(p: ^Parser, i, end: int) -> (img: Md_Image, ok: bool) {
	src := p.src
	if i + 1 >= end || src[i + 1] != '[' {
		return
	}
	j := i + 2
	img.alt_start = j
	for {
		if j >= end {
			return
		}
		if a, found := p.at[j]; found {
			j = p.atoms[a].end
			continue
		}
		if src[j] == '\\' {
			j += 2
			continue
		}
		if src[j] == '[' {
			return
		}
		if src[j] == ']' {
			break
		}
		j += 1
	}
	img.alt_end = j
	if j + 2 >= end || src[j + 1] != '(' {
		return
	}
	a, found := p.at[j + 2]
	if !found || !p.atoms[a].url || p.atoms[a].end > end {
		return
	}
	img.url_start, img.url_end = p.atoms[a].start, p.atoms[a].end
	j = img.url_end
	spaces :: proc(src: string, j, end: int) -> int {
		j := j
		for j < end && src[j] == ' ' {
			j += 1
		}
		return j
	}
	// The size.
	if k := spaces(src, j, end); k > j && k < end && src[k] == '=' {
		k += 1
		x := false
		for k < end && (is_digit(rune(src[k])) || (src[k] == 'x' && !x)) {
			x = x || src[k] == 'x'
			k += 1
		}
		if !x {
			return
		}
		j = k
	}
	// The title.
	if k := spaces(src, j, end); k > j && k < end && src[k] == '"' {
		close := strings.index_byte(src[k + 1:end], '"')
		if close < 0 {
			return
		}
		img.title_start, img.title_end = k + 1, k + 1 + close
		j = k + close + 2
	}
	j = spaces(src, j, end)
	if j >= end || src[j] != ')' {
		return
	}
	img.end = j + 1
	img.url = src[img.url_start:img.url_end]
	if len(img.url) >= 4 && strings.equal_fold(img.url[:4], "www.") {
		img.url = strings.concatenate({"https://", img.url}, context.temp_allocator)
	}
	return img, true
}

// quoted is where the text of the line src[start:end] starts after its quote
// markers ("> ", or a ">" that is all there is), and how many there are.
@(private = "file")
quoted :: proc(src: string, start, end: int) -> (body, quote: int) {
	body = start
	for {
		if strings.has_prefix(src[body:end], "> ") {
			body += 2
		} else if src[body:end] == ">" {
			body += 1
		} else {
			return
		}
		quote += 1
	}
}

// table_split splits the line src[start:end] of a table into its cells at each
// | that isn't escaped or in an atom; a | at either end only closes it. Each
// cell is without the spaces around it. It uses the temp allocator.
@(private = "file")
table_split :: proc(p: ^Parser, start, end: int) -> []Md_Cell {
	src := p.src
	s, e := start, end
	for s < e && src[s] == ' ' {
		s += 1
	}
	for e > s && src[e - 1] == ' ' {
		e -= 1
	}
	if s < e && src[s] == '|' {
		s += 1
	}
	if e > s && src[e - 1] == '|' && (e - 2 < s || src[e - 2] != '\\') {
		e -= 1
	}
	cells := make([dynamic]Md_Cell, context.temp_allocator)
	cell :: proc(cells: ^[dynamic]Md_Cell, src: string, a, b: int) {
		a, b := a, b
		for a < b && src[a] == ' ' {
			a += 1
		}
		for b > a && src[b - 1] == ' ' {
			b -= 1
		}
		append(cells, Md_Cell{a, b})
	}
	from := s
	j := s
	for j < e {
		if a, found := p.at[j]; found {
			j = p.atoms[a].end
			continue
		}
		switch src[j] {
		case '\\':
			j += 2
			continue
		case '|':
			cell(&cells, src, from, j)
			from = j + 1
		}
		j += 1
	}
	cell(&cells, src, from, max(from, min(j, e)))
	return cells[:]
}

// table_align reads the line under a table's column names, which has a cell
// of dashes for each column (|---|:--:|), with a colon on the side the column
// is aligned to, or on both sides for the middle. It needs at least one |.
@(private = "file")
table_align :: proc(line: string) -> (align: []Md_Align, ok: bool) {
	if strings.index_byte(line, '|') < 0 {
		return
	}
	t := strings.trim_space(line)
	t = strings.trim_prefix(t, "|")
	t = strings.trim_suffix(t, "|")
	out := make([dynamic]Md_Align, context.temp_allocator)
	for part in strings.split_iterator(&t, "|") {
		c := strings.trim_space(part)
		left := strings.has_prefix(c, ":")
		right := len(c) > 1 && strings.has_suffix(c, ":")
		dashes := c[1 if left else 0:len(c) - (1 if right else 0)]
		if len(dashes) == 0 || strings.trim_left(dashes, "-") != "" {
			return
		}
		switch {
		case left && right:
			append(&out, Md_Align.Center)
		case right:
			append(&out, Md_Align.Right)
		case:
			append(&out, Md_Align.Left)
		}
	}
	return out[:], len(out) > 0
}

// table_row writes a row of a table: `columns` cells, separated by a tab, of
// which those that the row doesn't have are empty and those it has beyond them
// are left out. It returns where each cell's text ended up.
@(private = "file")
table_row :: proc(
	p: ^Parser,
	cells: []Md_Cell,
	columns: int,
	allocator: runtime.Allocator,
) -> []Md_Cell {
	out := make([]Md_Cell, columns, allocator)
	for c in 0 ..< columns {
		if c > 0 {
			out_put(p.out, "\t", {})
		}
		at := out_len(p.out)
		if c < len(cells) && cells[c].start < cells[c].end {
			p.cell = true
			inline(p, cells[c].start, cells[c].end)
			p.cell = false
		}
		out[c] = {at, out_len(p.out)}
	}
	return out
}

@(private = "file")
utf8_first :: proc(s: string) -> rune {
	r, _ := utf8.decode_rune_in_string(s)
	return r
}

@(private = "file")
utf8_last :: proc(s: string) -> rune {
	r, _ := utf8.decode_last_rune_in_string(s)
	return r
}

@(private = "file")
is_alnum :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r)
}

@(private = "file")
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}
