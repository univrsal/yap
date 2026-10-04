package conn

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "client:platform"

/*
A message's text as written: several lines, and markdown. The timeline
shows the lines as they are and the markdown as styles; where a message
is shown in one line - a reply's line, a link to it, pins, search
results, notifications - markdown_plain takes the markers out and
one_line runs the lines together.

The markdown is a chat flavour, close to Discord's:

	**bold**  *italic*  _italic_  __underline__  ~~strike~~  `code`
	```                 a code block, to the closing fence or the end
	> quote             (> > nests)
	- item, * item      a bullet, shown as •
	1. item             a numbered item, as written
	[text](url)         a link showing `text`, to a web address
	\*                  a marker that's just the character

markdown_parse works on a message as it's shown (text_display_links), so
mentions, the server's emoji and links to messages are already there as
names and placeholders; they come in as atoms, with the web addresses
found in the text, and are never looked into, so `@foo_bar_baz` and
`https://x.org/a_b_c` stay as they are. Each comes out where it went in
the text without the markers, or at -1 if it went (the address of a
[text](url) link).

What's markup and what isn't, to keep ordinary text from turning into
it by accident:
- A marker opens only before something that isn't a space and closes
  only after one: `a * b` is plain.
- `_` doesn't open or close inside a word (`snake_case_name`), and `*`
  doesn't between two digits (`2*3*4`).
- A marker that isn't closed on its line is just the character.
- Blocks are line by line; styles don't go on past the end of a line.
- In code - a span or a block - nothing is markup.
*/

// one_line is `text` with its newlines as spaces, the same length, so
// spans into `text` still fit it. Allocated in `allocator` if it has any.
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
	Code, // in the mono face; on a background, unless the line is a code block's
}
Md_Styles :: bit_set[Md_Style;u8]

// A stretch of the text in one set of styles. A Rich_Text's runs cover
// its text, in order.
Md_Run :: struct {
	start, end: int,
	styles:     Md_Styles,
}

Md_Line_Kind :: enum u8 {
	Plain,
	Code, // a line of a code block
	Bullet, // a list item; its text starts with its indent and "• "
	Number, // a numbered one; starts with its indent and "1. "
}

// One line of the text, as the message has it (wrapping is the
// renderer's business).
Md_Line :: struct {
	start, end: int, // the line's text, without its newline
	kind:       Md_Line_Kind,
	quote:      int, // how many quotes deep it is; 0 for none
	marker:     int, // a list item's indent and marker, in bytes from `start`: where wrapped lines hang from
}

// A [text](url) link: where its text is, and where it goes.
Md_Link :: struct {
	start, end: int,
	url:        string,
}

// Something in the text the parser doesn't look into: a mention, one of
// the server's emoji, a link to a message, a web address (`url`, which
// is what a [text](url) link may point at).
Md_Atom :: struct {
	start, end: int,
	url:        bool,
}

Rich_Text :: struct {
	text:  string, // what's drawn: the markers gone
	runs:  []Md_Run,
	lines: []Md_Line,
	links: []Md_Link,
	atoms: []Md_Atom, // the ones given, where they are in `text`; -1 for gone
}

/*
markdown_parse is `shown` with its markdown worked out. `atoms` are
byte ranges of it that aren't to be looked into (see above), in any
order but not overlapping. All in `allocator`.
*/
markdown_parse :: proc(shown: string, atoms: []Md_Atom, allocator := context.temp_allocator) -> Rich_Text {
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

	in_fence := false
	rest := shown
	ls := 0 // where the line is in `shown`
	for line in strings.split_lines_iterator(&rest) {
		start := ls
		ls += len(line) + 1
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
		// A fence opens a block, unless it closes again on the line
		// (```x```), which is a code span. After it, a word is the
		// block's language; more than that is its first line.
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
		body := start
		end := start + len(line)
		for {
			if strings.has_prefix(shown[body:end], "> ") {
				body += 2
			} else if shown[body:end] == ">" {
				body += 1
			} else {
				break
			}
			ml.quote += 1
		}
		// A list item: its indent, then "- ", "* " or "1. ".
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
		for s in o.segs {
			if s.src <= a.start && a.end <= s.src + s.n {
				moved[i].start = s.out + a.start - s.src
				moved[i].end = s.out + a.end - s.src
				break
			}
		}
	}
	return {text, o.runs[:], lines[:], o.links[:], moved}
}

/*
markdown_plain is a message as shown (mentions_display, text_display)
in one line, with its markdown taken out: for the places a message is
summed up in a line. In the temp allocator.
*/
markdown_plain :: proc(shown: string) -> string {
	if !strings.contains_any(shown, "*_~`>[\\-0123456789") {
		return one_line(shown)
	}
	links := platform.find_links(shown)
	atoms := make([]Md_Atom, len(links), context.temp_allocator)
	for l, i in links {
		atoms[i] = {l.start, l.end, true}
	}
	return one_line(markdown_parse(shown, atoms).text)
}

/*
markdown_toggle puts `marker` (`**`, `*`, `__`, `~~`, a backtick) round
text[lo:hi], what's selected in a composer, or takes it away if it's
there: just outside the selection, or at both ends of it. With nothing
selected it puts a pair in, for typing between. It says where the
selection is afterwards. In the temp allocator.

For `*`, which is both italic and half of bold, a run of them counts as
italic when it's odd (`*`, `***`) and bold when it's two or more, so
italic and bold go on and off separately.
*/
markdown_toggle :: proc(text: string, lo, hi: int, marker: string) -> (out: string, new_lo, new_hi: int) {
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
	case len(sel) >= 2 * m && there(c, m, run_on(sel, 0, c), run_back(sel, len(sel), c)) && run_on(sel, 0, c) < len(sel):
		out = strings.concatenate({text[:lo], sel[m:len(sel) - m], text[hi:]}, context.temp_allocator)
		return out, lo, hi - 2 * m
	}
	out = strings.concatenate({text[:lo], marker, sel, marker, text[hi:]}, context.temp_allocator)
	return out, lo + m, hi + m
}

// What's been written so far, and where it came from.
@(private = "file")
Out :: struct {
	b:     strings.Builder,
	// Stretches copied from the source as they are: where atoms went.
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

// line_begin starts a line: after a newline, unless it's the first. The
// newline between two lines of a code block is code too, so a block is a
// run.
@(private = "file")
line_begin :: proc(o: ^Out, lines: []Md_Line, code := false) -> int {
	if len(lines) > 0 {
		out_put(o, "\n", {.Code} if code && lines[len(lines) - 1].kind == .Code else {})
	}
	return out_len(o)
}

// out_copy writes src[start:end] as it is, in `styles`.
@(private = "file")
out_copy :: proc(o: ^Out, src: string, start, end: int, styles: Md_Styles) {
	if end <= start {
		return
	}
	at := out_len(o)
	strings.write_string(&o.b, src[start:end])
	if n := len(o.segs); n > 0 && o.segs[n - 1].src + o.segs[n - 1].n == start && o.segs[n - 1].out + o.segs[n - 1].n == at {
		o.segs[n - 1].n += end - start
	} else {
		append(&o.segs, Seg{start, at, end - start})
	}
	out_run(o, at, out_len(o), styles)
}

// out_put writes text that isn't the source's (a bullet, a newline).
@(private = "file")
out_put :: proc(o: ^Out, s: string, styles: Md_Styles) {
	at := out_len(o)
	strings.write_string(&o.b, s)
	out_run(o, at, out_len(o), styles)
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
	at:    map[int]int, // atoms by where they start
	out:   ^Out,
}

@(private = "file")
Tok_Kind :: enum u8 {
	Text, // copied as it is
	Code, // a code span's content
	Delim, // a run of * _ or ~, as much of it as isn't used up
	Link_Open, // where a [text](url) link's text starts and ends
	Link_Close,
}

@(private = "file")
Tok :: struct {
	kind:                  Tok_Kind,
	start, end:            int, // in the source
	styles:                Md_Styles,
	// Delim: its character, whether it may open or close, and how much of
	// it closing (from the left) and opening (from the right) used up.
	ch:                    u8,
	can_open, can_close:   bool,
	used_left, used_right: int,
	url:                   string, // Link_Close: where it goes
}

@(private = "file")
tok_count :: proc(t: Tok) -> int {
	return t.end - t.start - t.used_left - t.used_right
}

// inline writes src[start:end], one line's text, with its styles.
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
	// While in a link's text: where its ] is, and where the link ends.
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
			if i + 1 < end && strings.index_byte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", src[i + 1]) >= 0 {
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
				append(&toks, Tok{kind = .Delim, start = i, end = i + n, ch = ch, can_open = opens, can_close = closes})
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
			out_copy(o, src, t.start, t.end, t.styles + {.Code})
		case .Delim:
			out_copy(o, src, t.start + t.used_left, t.end - t.used_right, t.styles)
		case .Link_Open:
			link_start = out_len(o)
		case .Link_Close:
			append(&o.links, Md_Link{link_start, out_len(o), strings.clone(t.url, o.b.buf.allocator)})
		}
	}
}

/*
pair_delims matches closing runs of * _ ~ with the nearest opening run
of the same character before them, as CommonMark does (simplified): two
of each where both runs have two (bold, underline, strike), else one
(italic; strike takes two). What's between a pair gets its style, and
the runs between that are left open stay as they are.
*/
@(private = "file")
pair_delims :: proc(toks: []Tok) {
	for c in 0 ..< len(toks) {
		if toks[c].kind != .Delim || !toks[c].can_close {
			continue
		}
		for tok_count(toks[c]) > 0 {
			o := -1
			search: for k := c - 1; k >= 0; k -= 1 {
				#partial switch toks[k].kind {
				case .Link_Open, .Link_Close:
					break search // pairs don't cross a link's edges
				case .Delim:
					if toks[k].ch == toks[c].ch && toks[k].can_open && tok_count(toks[k]) > 0 {
						o = k
						break search
					}
				}
			}
			if o < 0 {
				break
			}
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
			for k in o + 1 ..< c {
				toks[k].styles += {style}
				// What was left open in there stays as it is.
				if toks[k].kind == .Delim {
					toks[k].can_open = false
				}
			}
			toks[o].used_right += n
			toks[c].used_left += n
		}
	}
}

// return_to_text gives up on an opener that can't be closed by `c` (a
// single ~), so the search goes on past it.
@(private = "file")
return_to_text :: proc(toks: []Tok, o, c: int) {
	toks[o].can_open = false
}

// run_length is how many of the character at `i` there are in a row.
@(private = "file")
run_length :: proc(src: string, i, end: int) -> int {
	n := 1
	for i + n < end && src[i + n] == src[i] {
		n += 1
	}
	return n
}

// find_backticks finds a run of exactly `n` backticks from `from` on,
// outside atoms: where a code span closes. -1 if there's none.
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

/*
find_link sees whether a [text](url) link starts at `i`: some text, then
`](`, a web address the text has as an atom, and `)`. It says where the
`]` is, where the link ends, and the address.
*/
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
