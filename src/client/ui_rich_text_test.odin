#+build !wasi
package client

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:render"

// Characters are 8 pixels wide in Regular, 10 in Bold, 9 in Mono (and 8
// in the italics); lines are 16 tall.
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

	// However narrow, every line takes something, and all but the spaces
	// it breaks at gets laid out.
	r = rich_make("**x** `y` _z_\n> - w", nil, nil, nil, false)
	total := 0
	for vl in rich_layout(ctx, &r, 1) {
		testing.expect(t, vl.end > vl.start)
		total += vl.end - vl.start
	}
	testing.expect_value(t, total, len(r.text) - strings.count(r.text, " ") - strings.count(r.text, "\n"))
}

@(test)
test_rich_spans :: proc(t: ^testing.T) {
	// Mentions, emoji and links to messages move with the text; a web
	// address a [text](url) takes goes, others stay.
	shown := "**@Ann**  [site](https://a.org) https://b.org"
	ann := strings.index(shown, "@Ann")
	icon := strings.index(shown, "")
	r := rich_make(shown, {{ann, ann + 4, true}}, {{icon, icon + 3, 2}}, nil, true)
	testing.expect_value(t, r.text, "@Ann  site https://b.org")
	testing.expect_value(t, r.mentions[0], conn.Mention_Span{0, 4, true})
	testing.expect_value(t, r.emoji[0], conn.Emoji_Span{5, 8, 2})
	testing.expect_value(t, len(r.links), 1)
	testing.expect_value(t, r.text[r.links[0].start:r.links[0].end], "site")
	testing.expect_value(t, r.links[0].url, "https://a.org")
	testing.expect_value(t, len(r.web), 1)
	testing.expect_value(t, r.text[r.web[0].start:r.web[0].end], "https://b.org")

	// Without `links`, addresses aren't looked for.
	r = rich_make("https://b.org", nil, nil, nil, false)
	testing.expect_value(t, len(r.web), 0)
}
