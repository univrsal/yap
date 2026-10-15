package conn

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
//   [text](url)         a link that shows `text` and goes to a web address
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
}

// One line of the text as it is in the message. Wrapping is left to the
// renderer.
Md_Line :: struct {
	start, end: int, // the line's text, without its newline
	kind:       Md_Line_Kind,
	quote:      int, // how many levels deep the quote is; 0 if it isn't quoted
	marker:     int, // the length in bytes of a list item's indent and marker, counted from `start`; wrapped lines are indented to this position
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
	text:  string, // the text that is drawn, without the markers
	runs:  []Md_Run,
	lines: []Md_Line,
	links: []Md_Link,
	atoms: []Md_Atom, // the atoms that were passed in, at their positions in `text`; -1 if the atom was removed
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

	in_fence := false
	rest := shown
	ls := 0 // the position of the line in `shown`
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

// markdown_plain returns a message as shown (see mentions_display and
// text_display) on a single line with its markdown removed. It is meant for
// places where a message is summarized in one line. The result is allocated in
// the temp allocator.
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
}

@(private = "file")
Tok_Kind :: enum u8 {
	Text, // copied unchanged
	Code, // the content of a code span
	Delim, // a run of * _ or ~, minus the part that has been used up
	Link_Open, // the start and end of a [text](url) link's text
	Link_Close,
}

@(private = "file")
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

@(private = "file")
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
			out_copy(o, src, t.start, t.end, t.styles + {.Code})
		case .Delim:
			out_copy(o, src, t.start + t.used_left, t.end - t.used_right, t.styles)
		case .Link_Open:
			link_start = out_len(o)
		case .Link_Close:
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
					break search // pairs must not cross the boundaries of a link
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
				// Markers that were left open in there stay unchanged.
				if toks[k].kind == .Delim {
					toks[k].can_open = false
				}
			}
			toks[o].used_right += n
			toks[c].used_left += n
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
