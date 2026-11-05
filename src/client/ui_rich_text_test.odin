#+build !wasi
package client

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:render"
import "client:richtext"

// Characters are 8 pixels wide in Regular, 10 in Bold, 9 in Mono (and 8 in the
// italics). Lines are 16 pixels tall.
@(private = "file")
rich_test_ctx :: proc() -> ^mu.Context {
	ctx := new(mu.Context)
	mu.init(ctx)
	ctx.text_width = proc(font: mu.Font, s: string) -> i32 {
		per: i32 = 8
		#partial switch render.font_style(font) {
		case .Bold:
			per = 10
		case .Mono:
			per = 9
		}
		return i32(utf8.rune_count_in_string(s)) * per
	}
	ctx.text_height = proc(font: mu.Font) -> i32 {return 16}
	ctx.style.font = render.CHAT_FONT
	return ctx
}

@(private = "file")
lines_of :: proc(ctx: ^mu.Context, r: ^Rich, width: i32) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for vl in rich_layout(ctx, r, width) {
		append(&out, r.text[vl.start:vl.end])
	}
	return out[:]
}

@(test)
test_rich_layout :: proc(t: ^testing.T) {
	ctx := rich_test_ctx()
	defer free(ctx)

	// Plain text: lines, and an empty one.
	r := rich_plain("a\n\nb")
	testing.expect_value(t, len(rich_layout(ctx, &r, 100)), 3)
	testing.expect_value(t, rich_height(ctx, &r, 100), 48)

	// Widths are each run's: bold is wider, so it wraps sooner.
	r = rich_make("**aaaa** bb", nil, nil, nil, false)
	testing.expect_value(t, rich_width(ctx, &r, 0, len(r.text)), 4 * 10 + 3 * 8)
	got := lines_of(ctx, &r, 50)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "aaaa")
	testing.expect_value(t, got[1], "bb")
	r = rich_make("aaaa bb", nil, nil, nil, false)
	testing.expect_value(t, len(lines_of(ctx, &r, 56)), 1)

	// A quote is indented a step a level.
	r = rich_make("> q\n> > qq\nno", nil, nil, nil, false)
	vls := rich_layout(ctx, &r, 200)
	testing.expect_value(t, vls[0].x, 14)
	testing.expect_value(t, vls[1].x, 28)
	testing.expect_value(t, vls[2].x, 0)

	// A list item's wrapped lines hang under its text, after "• ".
	r = rich_make("- aaaa bbbb cccc", nil, nil, nil, false)
	vls = rich_layout(ctx, &r, 80)
	testing.expect(t, len(vls) >= 2)
	testing.expect_value(t, vls[0].x, 0)
	testing.expect_value(t, r.text[vls[0].start:vls[0].end], "• aaaa")
	for vl in vls[1:] {
		testing.expect_value(t, vl.x, 16)
	}

	// A code block's lines are inside its box, and break anywhere.
	r = rich_make("```\nabcdefghij klm\n```", nil, nil, nil, false)
	vls = rich_layout(ctx, &r, 6 + 6 + 5 * 9)
	testing.expect_value(t, vls[0].x, 6)
	testing.expect_value(t, r.text[vls[0].start:vls[0].end], "abcde")
	testing.expect_value(t, r.text[vls[1].start:vls[1].end], "fghij")
	testing.expect_value(t, r.text[vls[2].start:vls[2].end], " klm")

	// However narrow the width is, every line takes at least one character,
	// and everything except the spaces it breaks at gets laid out.
	r = rich_make("**x** `y` _z_\n> - w", nil, nil, nil, false)
	total := 0
	for vl in rich_layout(ctx, &r, 1) {
		testing.expect(t, vl.end > vl.start)
		total += vl.end - vl.start
	}
	testing.expect_value(
		t,
		total,
		len(r.text) - strings.count(r.text, " ") - strings.count(r.text, "\n"),
	)
}

@(test)
test_rich_headings :: proc(t: ^testing.T) {
	ctx := rich_test_ctx()
	defer free(ctx)

	// Headings of level 1 to 3 are in fonts of their own, the others are as
	// big as the text; all of them are bold.
	r := rich_make("# one\n### three\n#### four\ntext", nil, nil, nil, false)
	testing.expect_value(t, rich_line_font(ctx, r.lines[0]), render.heading_font(render.CHAT_FONT, 1, .Regular))
	testing.expect(t, rich_line_font(ctx, r.lines[0]) != render.CHAT_FONT)
	testing.expect(t, rich_line_font(ctx, r.lines[1]) != rich_line_font(ctx, r.lines[0]))
	testing.expect_value(t, rich_line_font(ctx, r.lines[2]), render.CHAT_FONT)
	testing.expect_value(t, rich_line_font(ctx, r.lines[3]), render.CHAT_FONT)
	testing.expect_value(t, rich_width(ctx, &r, r.lines[2].start, r.lines[2].end), 4 * 10)
	// Text that isn't in the chat's font has headings as big as itself.
	ctx.style.font = nil
	testing.expect_value(t, rich_line_font(ctx, r.lines[0]), mu.Font(nil))
}

@(test)
test_rich_tables :: proc(t: ^testing.T) {
	ctx := rich_test_ctx()
	defer free(ctx)

	// Wide enough: each column is as wide as its widest cell (the column names
	// are bold), inset by 6 on each side, and the text is aligned in it.
	r := rich_make("| a | bb |\n|---|--:|\n| ccc | d |", nil, nil, nil, false)
	vls := rich_layout(ctx, &r, 200)
	testing.expect_value(t, len(vls), 4)
	testing.expect_value(t, r.text[vls[0].start:vls[0].end], "a")
	testing.expect_value(t, r.text[vls[3].start:vls[3].end], "d")
	testing.expect(t, !vls[0].same_row && vls[1].same_row && !vls[2].same_row && vls[3].same_row)
	testing.expect_value(t, vls[0].x, 6)
	testing.expect_value(t, vls[1].cell_x, 24 + 12)
	testing.expect_value(t, vls[1].x, 36 + 6) // "bb" fills its column
	testing.expect_value(t, vls[3].x, 36 + 6 + 20 - 8) // "d" is on the right
	testing.expect(t, vls[0].row_first && !vls[0].table_last && vls[3].table_last)
	// A row is a line and the space around it.
	testing.expect_value(t, rich_height(ctx, &r, 200), 2 * (16 + 2 * 3))

	// Too narrow: the columns share the width and the cells wrap, every cell
	// of a row has as many lines as its tallest, and all the text is there.
	r = rich_make("| a | bb |\n|---|---|\n| ccc dd | e |", nil, nil, nil, false)
	vls = rich_layout(ctx, &r, 40)
	total := 0
	rows := 0
	for vl, i in vls {
		total += vl.end - vl.start
		if !vl.same_row {
			rows += 1
		} else {
			testing.expect_value(t, vl.h, vls[i - 1].h)
		}
		testing.expect(t, vl.cell_x + vl.cell_w <= 40)
	}
	testing.expect_value(t, total, len("a") + len("bb") + len("cccdd") + len("e"))
	testing.expect(t, rows > 2)
	testing.expect(t, vls[len(vls) - 1].table_last)

	// Text after a table is laid out as before.
	r = rich_make("|a|\n|-|\n|b|\nafter", nil, nil, nil, false)
	vls = rich_layout(ctx, &r, 200)
	testing.expect_value(t, len(vls), 3)
	testing.expect_value(t, vls[2].cell, -1)
	testing.expect_value(t, r.text[vls[2].start:vls[2].end], "after")
}

@(test)
test_rich_spans :: proc(t: ^testing.T) {
	// Mentions, emoji and links to messages move with the text. A web
	// address that a [text](url) takes goes away, while others stay.
	shown := "**@Ann**  [site](https://a.org) https://b.org"
	ann := strings.index(shown, "@Ann")
	icon := strings.index(shown, "")
	r := rich_make(shown, {{ann, ann + 4, true}}, {{icon, icon + 3, 2}}, nil, true)
	testing.expect_value(t, r.text, "@Ann  site https://b.org")
	testing.expect_value(t, r.mentions[0], richtext.Mention_Span{0, 4, true})
	testing.expect_value(t, r.emoji[0], richtext.Emoji_Span{5, 8, 2})
	testing.expect_value(t, len(r.links), 1)
	testing.expect_value(t, r.text[r.links[0].start:r.links[0].end], "site")
	testing.expect_value(t, r.links[0].url, "https://a.org")
	testing.expect_value(t, len(r.web), 1)
	testing.expect_value(t, r.text[r.web[0].start:r.web[0].end], "https://b.org")

	// Without `links`, addresses aren't looked for.
	r = rich_make("https://b.org", nil, nil, nil, false)
	testing.expect_value(t, len(r.web), 0)
}
