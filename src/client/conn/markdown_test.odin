#+build !wasi
package conn

import "core:strings"
import "core:testing"

// md_show writes a Rich_Text's text with its styled runs as
// [letters:text]: B bold, I italic, U underline, S strike, C code.
@(private = "file")
md_show :: proc(rt: Rich_Text) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rt.runs {
		if r.styles == {} {
			strings.write_string(&b, rt.text[r.start:r.end])
			continue
		}
		strings.write_byte(&b, '[')
		letters := [Md_Style]u8 {
			.Bold      = 'B',
			.Italic    = 'I',
			.Underline = 'U',
			.Strike    = 'S',
			.Code      = 'C',
		}
		for s in Md_Style {
			if s in r.styles {
				strings.write_byte(&b, letters[s])
			}
		}
		strings.write_byte(&b, ':')
		strings.write_string(&b, rt.text[r.start:r.end])
		strings.write_byte(&b, ']')
	}
	return strings.to_string(b)
}

// md_atoms is an atom for each of `parts` where it first is in `text`.
@(private = "file")
md_atoms :: proc(text: string, parts: ..string) -> []Md_Atom {
	atoms := make([]Md_Atom, len(parts), context.temp_allocator)
	for part, i in parts {
		at := strings.index(text, part)
		atoms[i] = {at, at + len(part), strings.has_prefix(part, "http") || strings.has_prefix(part, "www.")}
	}
	return atoms
}

@(test)
test_markdown_inline :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"plain text", "plain text"},
		{"**bold**", "[B:bold]"},
		{"*it* and _it_", "[I:it] and [I:it]"},
		{"__under__", "[U:under]"},
		{"~~gone~~", "[S:gone]"},
		{"`co*de*`", "[C:co*de*]"},
		{"***both***", "[BI:both]"},
		{"**bold _and italic_**", "[B:bold ][BI:and italic]"},
		{"_**nested**_", "[BI:nested]"},
		{"a **b** c *d* e", "a [B:b] c [I:d] e"},
		{"**a** **b**", "[B:a] [B:b]"},
		{"in*word*s", "in[I:word]s"},
		// Not markup.
		{"2*3*4", "2*3*4"},
		{"snake_case_name", "snake_case_name"},
		{"a * b * c", "a * b * c"},
		{"**unclosed", "**unclosed"},
		{"~single~", "~single~"},
		{"a ` b", "a ` b"},
		{"** a**", "** a**"},
		// Escapes.
		{"\\*not\\* \\\\", "*not* \\"},
		{"\\a stays", "\\a stays"},
		// Code spans: a run closes with a run as long; nothing inside counts.
		{"``a`b``", "[C:a`b]"},
		{"**`x`**", "[BC:x]"},
		{"```x```", "[C:x]"},
		// Styles don't go past a line's end.
		{"**a\nb**", "**a\nb**"},
		{"line one\n*two*", "line one\n[I:two]"},
	}
	for c in cases {
		got := md_show(markdown_parse(c[0], nil))
		testing.expectf(t, got == c[1], "%q: %q, not %q", c[0], got, c[1])
	}
}

@(test)
test_markdown_blocks :: proc(t: ^testing.T) {
	rt := markdown_parse("> quoted **x**\n> > deep\nnot", nil)
	testing.expect_value(t, md_show(rt), "quoted [B:x]\ndeep\nnot")
	testing.expect_value(t, len(rt.lines), 3)
	testing.expect_value(t, rt.lines[0].quote, 1)
	testing.expect_value(t, rt.lines[1].quote, 2)
	testing.expect_value(t, rt.lines[2].quote, 0)
	// `>` without a space isn't a quote: >_<
	testing.expect_value(t, markdown_parse(">_<", nil).text, ">_<")

	rt = markdown_parse("- one\n* two *it*\n  - nested\n1. first\n10. tenth\n-not\n2020 was", nil)
	testing.expect_value(t, md_show(rt), "• one\n• two [I:it]\n  • nested\n1. first\n10. tenth\n-not\n2020 was")
	kinds := [?]Md_Line_Kind{.Bullet, .Bullet, .Bullet, .Number, .Number, .Plain, .Plain}
	markers := [?]int{4, 4, 6, 3, 4, 0, 0}
	testing.expect_value(t, len(rt.lines), len(kinds))
	for l, i in rt.lines {
		testing.expectf(t, l.kind == kinds[i] && l.marker == markers[i], "line %d: %v", i, l)
		testing.expect(t, rt.text[l.start:l.end] == strings.split_lines(rt.text, context.temp_allocator)[i])
	}

	// A code block: the fences go, a language word with them; nothing
	// inside is markup, indentation stays.
	rt = markdown_parse("before\n```odin\nlet *x* = 1\n    **y**\n```\nafter *z*", nil)
	testing.expect_value(t, md_show(rt), "before\n[C:let *x* = 1\n    **y**]\nafter [I:z]")
	testing.expect_value(t, len(rt.lines), 4)
	testing.expect_value(t, rt.lines[1].kind, Md_Line_Kind.Code)
	testing.expect_value(t, rt.lines[2].kind, Md_Line_Kind.Code)
	testing.expect_value(t, rt.text[rt.lines[2].start:rt.lines[2].end], "    **y**")
	testing.expect_value(t, rt.lines[3].kind, Md_Line_Kind.Plain)
	// A fence that's never closed runs to the end; more than a word after
	// the fence is the first line.
	rt = markdown_parse("```some code\nmore *x*", nil)
	testing.expect_value(t, md_show(rt), "[C:some code\nmore *x*]")
	testing.expect(t, rt.lines[0].kind == .Code && rt.lines[1].kind == .Code)

	// Runs cover the text; lines don't overlap.
	rt = markdown_parse("- **a** b\n> `c`\n```\nd\n```", nil)
	at := 0
	for r in rt.runs {
		testing.expect_value(t, r.start, at)
		at = r.end
	}
	testing.expect_value(t, at, len(rt.text))
	testing.expect_value(t, markdown_parse("", nil).text, "")
	testing.expect_value(t, len(markdown_parse("", nil).lines), 1)
}

@(test)
test_markdown_atoms :: proc(t: ^testing.T) {
	// Atoms are never looked into, and move with the text.
	text := "hi @foo_bar_baz *x* https://x.org/a_b_c _i_"
	rt := markdown_parse(text, md_atoms(text, "@foo_bar_baz", "https://x.org/a_b_c"))
	testing.expect_value(t, md_show(rt), "hi @foo_bar_baz [I:x] https://x.org/a_b_c [I:i]")
	for a, i in rt.atoms {
		want := [?]string{"@foo_bar_baz", "https://x.org/a_b_c"}
		testing.expectf(t, rt.text[a.start:a.end] == want[i], "atom %d at %v", i, a)
	}

	// Styled atoms.
	text = "*@Name* and **@Other_one**"
	rt = markdown_parse(text, md_atoms(text, "@Name", "@Other_one"))
	testing.expect_value(t, md_show(rt), "[I:@Name] and [B:@Other_one]")
	testing.expect_value(t, rt.atoms[0], Md_Atom{0, 5, false})
	testing.expect_value(t, rt.text[rt.atoms[1].start:rt.atoms[1].end], "@Other_one")

	// A marker character inside an atom closes nothing.
	text = "*a @x*y b"
	rt = markdown_parse(text, md_atoms(text, "@x*y"))
	testing.expect_value(t, md_show(rt), "*a @x*y b")

	// Inside code, atoms stay (and move).
	text = "`@who` - ```\nhttps://x.org\n```"
	rt = markdown_parse(text, md_atoms(text, "@who", "https://x.org"))
	testing.expect_value(t, rt.text[rt.atoms[0].start:rt.atoms[0].end], "@who")
	testing.expect_value(t, rt.text[rt.atoms[1].start:rt.atoms[1].end], "https://x.org")
}

@(test)
test_markdown_links :: proc(t: ^testing.T) {
	text := "see [the **site**](https://x.org/a_b) now"
	rt := markdown_parse(text, md_atoms(text, "https://x.org/a_b"))
	testing.expect_value(t, md_show(rt), "see the [B:site] now")
	testing.expect_value(t, len(rt.links), 1)
	testing.expect_value(t, rt.text[rt.links[0].start:rt.links[0].end], "the site")
	testing.expect_value(t, rt.links[0].url, "https://x.org/a_b")
	// The address went with the markup.
	testing.expect_value(t, rt.atoms[0].start, -1)

	text = "[a](www.x.org) [b](https://y.org)"
	rt = markdown_parse(text, md_atoms(text, "www.x.org", "https://y.org"))
	testing.expect_value(t, rt.text, "a b")
	testing.expect_value(t, len(rt.links), 2)
	testing.expect_value(t, rt.links[0].url, "https://www.x.org")
	testing.expect_value(t, rt.links[1], Md_Link{2, 3, "https://y.org"})

	// Not links: no web address, nothing to show, a space, a mention.
	for not_link in ([?]string{"[a](b)", "[](https://x.org)", "[a] (https://x.org)", "[a](@x)"}) {
		atoms: []Md_Atom
		if strings.contains(not_link, "https") {
			atoms = md_atoms(not_link, "https://x.org")
		} else if strings.contains(not_link, "@x") {
			atoms = md_atoms(not_link, "@x")
		}
		rt = markdown_parse(not_link, atoms)
		testing.expectf(t, len(rt.links) == 0 && rt.text == not_link, "%q: %v", not_link, rt)
	}
	// Styles don't pair across a link's edge.
	text = "*a [b* c](https://x.org)"
	rt = markdown_parse(text, md_atoms(text, "https://x.org"))
	testing.expect_value(t, md_show(rt), "*a b* c")
}

@(test)
test_markdown_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, markdown_plain("just words"), "just words")
	testing.expect_value(t, markdown_plain("**a** _b_\n> c [d](https://x.org) https://y.org/a_b_c"), "a b c d https://y.org/a_b_c")
	testing.expect_value(t, markdown_plain("- one\n- two"), "• one • two")
	testing.expect_value(t, markdown_plain("```\ncode\n```"), "code")
}

@(test)
test_markdown_toggle :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		lo, hi: int,
		marker: string,
		out:    string,
		sel:    [2]int,
	}
	cases := [?]Case {
		// Wrapped, and unwrapped again from outside or inside.
		{"say hi now", 4, 6, "**", "say **hi** now", {6, 8}},
		{"say **hi** now", 6, 8, "**", "say hi now", {4, 6}},
		{"say **hi** now", 4, 10, "**", "say hi now", {4, 6}},
		// Nothing selected: a pair, with the caret between.
		{"ab", 1, 1, "`", "a``b", {2, 2}},
		{"", 0, 0, "~~", "~~~~", {2, 2}},
		// Italic and bold go on and off apart.
		{"**x**", 2, 3, "*", "***x***", {3, 4}},
		{"***x***", 3, 4, "*", "**x**", {2, 3}},
		{"***x***", 3, 4, "**", "*x*", {1, 2}},
		{"*x*", 1, 2, "**", "***x***", {3, 4}},
		// Underline isn't italic.
		{"_x_", 1, 2, "__", "___x___", {3, 4}},
		{"__x__", 2, 3, "__", "x", {0, 1}},
		// Markers alone aren't taken for a wrapped selection.
		{"****", 0, 4, "**", "********", {2, 6}},
	}
	for c in cases {
		out, lo, hi := markdown_toggle(c.text, c.lo, c.hi, c.marker)
		testing.expectf(t, out == c.out && lo == c.sel[0] && hi == c.sel[1], "%q [%d:%d] %q: %q [%d:%d]", c.text, c.lo, c.hi, c.marker, out, lo, hi)
	}
}

// Any text parses: random strings of markup and atoms, checked for what
// every result has to be.
@(test)
test_markdown_random :: proc(t: ^testing.T) {
	pieces := [?]string{"*", "_", "~", "`", "[", "]", "(", ")", "\\", "> ", "- ", "1. ", " ", "\n", "a", "é", "```", "URL", "@M"}
	state: u64 = 0x9e3779b97f4a7c15
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	for _ in 0 ..< 5000 {
		b := strings.builder_make(context.temp_allocator)
		atoms := make([dynamic]Md_Atom, context.temp_allocator)
		n := int(next(&state) % 24)
		for _ in 0 ..< n {
			piece := pieces[next(&state) % len(pieces)]
			switch piece {
			case "URL":
				at := strings.builder_len(b)
				strings.write_string(&b, "https://x.org/a_b*c")
				append(&atoms, Md_Atom{at, strings.builder_len(b), true})
			case "@M":
				at := strings.builder_len(b)
				strings.write_string(&b, "@m_*`")
				append(&atoms, Md_Atom{at, strings.builder_len(b), false})
			case:
				strings.write_string(&b, piece)
			}
		}
		text := strings.to_string(b)
		rt := markdown_parse(text, atoms[:])
		at := 0
		for r in rt.runs {
			testing.expectf(t, r.start == at && r.end > r.start, "%q: runs %v", text, rt.runs)
			at = r.end
		}
		testing.expectf(t, at == len(rt.text), "%q: runs end at %d of %d", text, at, len(rt.text))
		last := 0
		for l in rt.lines {
			testing.expectf(t, l.start >= last && l.end >= l.start && l.end <= len(rt.text), "%q: lines %v", text, rt.lines)
			last = l.end
		}
		for l in rt.links {
			testing.expectf(t, l.start < l.end && l.end <= len(rt.text), "%q: links %v", text, rt.links)
		}
		for a, i in rt.atoms {
			if a.start >= 0 {
				src := atoms[i]
				testing.expectf(t, rt.text[a.start:a.end] == text[src.start:src.end], "%q: atom %d", text, i)
			}
		}
	}
}
