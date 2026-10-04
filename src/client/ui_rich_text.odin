package client

import "core:fmt"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

/*
A message's text as the timeline draws it: its markdown worked out
(conn.markdown_parse) and laid out in lines.

Rich is a message's text as shown (text_display_links) after the
parse, with what's in it - mentions, the server's emoji, links to
messages and web addresses - moved to where they are in the parsed
text. Text that isn't a message's (a system line, "deleted") is a Rich
too, without markdown: rich_plain.

Each line of the text is laid out on its own, wrapped to the width as
the chat always wrapped (at the last space that fits, or anywhere in a
word too long for a line), but measured run by run in each run's face:
bold, italic, code in the mono face. A quote is indented a step for
each level, with a bar in the step; a list item's wrapped lines hang
under its text, after the bullet or number; a code block's lines are
indented a little inside a box that runs the width of the column, and
break anywhere rather than at spaces.

rich_layout is the one place lines are worked out: message_height
measures with it and chat_message draws with it, so a message is the
height it was worked out to be (see the top of ui_timeline.odin).
*/

// How far a quote is indented, each level, and its bar in that room.
@(private = "file")
QUOTE_STEP :: 14
@(private = "file")
QUOTE_BAR_X :: 3
@(private = "file")
QUOTE_BAR_W :: 3
@(private = "file")
QUOTE_BAR_COLOR :: mu.Color{95, 95, 95, 255}
// How far a code block's text is inside its box, and the box; and the
// background of code in a line.
@(private = "file")
CODE_PAD :: 6
@(private = "file")
CODE_BLOCK_COLOR :: mu.Color{36, 36, 36, 255}
@(private = "file")
CODE_SPAN_COLOR :: mu.Color{28, 28, 28, 255}

Rich :: struct {
	using rt:  conn.Rich_Text,
	mentions:  []conn.Mention_Span,
	emoji:     []conn.Emoji_Span,
	msg_links: []conn.Link_Span,
	web:       []platform.Link, // web addresses not taken by a [text](url)
}

// One line as drawn: text[start:end], `x` in from the column's left.
Rich_Line :: struct {
	start, end: int,
	x:          i32,
	line:       int, // which of the text's lines (Rich_Text.lines) it's part of
}

/*
rich_make is a message's text, shown (text_display_links) with its
mentions, the server's emoji and links to messages, as it's drawn: its
markdown, and with `links`, its web addresses. In the temp allocator.
*/
rich_make :: proc(
	shown: string,
	mentions: []conn.Mention_Span,
	emoji: []conn.Emoji_Span,
	msg_links: []conn.Link_Span,
	links: bool,
) -> Rich {
	// Web addresses, but for where a link to a message is.
	web: [dynamic]platform.Link
	if links {
		outer: for l in platform.find_links(shown) {
			for ml in msg_links {
				if l.start < ml.end && ml.start < l.end {
					continue outer
				}
			}
			append(&web, l)
		}
	}
	atoms := make([dynamic]conn.Md_Atom, context.temp_allocator)
	for m in mentions {
		append(&atoms, conn.Md_Atom{m.start, m.end, false})
	}
	for e in emoji {
		append(&atoms, conn.Md_Atom{e.start, e.end, false})
	}
	for l in msg_links {
		append(&atoms, conn.Md_Atom{l.start, l.end, false})
	}
	for l in web {
		append(&atoms, conn.Md_Atom{l.start, l.end, true})
	}
	r := Rich {
		rt = conn.markdown_parse(shown, atoms[:]),
	}
	// Each list in the order it went in, where the atoms went; the web
	// addresses a [text](url) took are gone.
	at := 0
	moved :: proc(a: conn.Md_Atom) -> (start, end: int, ok: bool) {
		return a.start, a.end, a.start >= 0
	}
	ms := make([dynamic]conn.Mention_Span, context.temp_allocator)
	for m in mentions {
		if s, e, ok := moved(r.atoms[at]); ok {
			append(&ms, conn.Mention_Span{s, e, m.me})
		}
		at += 1
	}
	es := make([dynamic]conn.Emoji_Span, context.temp_allocator)
	for em in emoji {
		if s, e, ok := moved(r.atoms[at]); ok {
			append(&es, conn.Emoji_Span{s, e, em.index})
		}
		at += 1
	}
	ls := make([dynamic]conn.Link_Span, context.temp_allocator)
	for l in msg_links {
		if s, e, ok := moved(r.atoms[at]); ok {
			append(&ls, conn.Link_Span{s, e, l.link})
		}
		at += 1
	}
	ws := make([dynamic]platform.Link, context.temp_allocator)
	for _ in web {
		if s, e, ok := moved(r.atoms[at]); ok {
			append(&ws, platform.Link{s, e})
		}
		at += 1
	}
	delete(web)
	r.mentions, r.emoji, r.msg_links, r.web = ms[:], es[:], ls[:], ws[:]
	return r
}

// rich_plain is text that isn't a message's: no markdown, nothing in it,
// a line for each of its lines. In the temp allocator.
rich_plain :: proc(text: string) -> Rich {
	r: Rich
	r.text = text
	if len(text) > 0 {
		r.runs = slice.clone([]conn.Md_Run{{0, len(text), {}}}, context.temp_allocator)
	}
	lines := make([dynamic]conn.Md_Line, context.temp_allocator)
	start := 0
	for i in 0 ..= len(text) {
		if i == len(text) || text[i] == '\n' {
			append(&lines, conn.Md_Line{start = start, end = i})
			start = i + 1
		}
	}
	r.lines = lines[:]
	return r
}

// rich_run is which of the runs text[i] is in (the last one past the end).
@(private = "file")
rich_run :: proc(r: ^Rich, i: int) -> int {
	lo, hi := 0, len(r.runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.runs[mid].end <= i {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return min(lo, len(r.runs) - 1)
}

// rich_font is the font the runs in `styles` are drawn in: the current
// one (the chat's) in the face for them.
rich_font :: proc(ctx: ^mu.Context, styles: conn.Md_Styles) -> mu.Font {
	style := render.Font_Style.Regular
	switch {
	case .Code in styles:
		style = .Mono
	case .Bold in styles && .Italic in styles:
		style = .Bold_Italic
	case .Bold in styles:
		style = .Bold
	case .Italic in styles:
		style = .Italic
	}
	return render.font_with_style(ctx.style.font, style)
}

// rich_styles_at is the styles of the run text[i] is in.
@(private = "file")
rich_styles_at :: proc(r: ^Rich, i: int) -> conn.Md_Styles {
	if len(r.runs) == 0 {
		return {}
	}
	return r.runs[rich_run(r, i)].styles
}

// rich_width is how wide text[a:b] is drawn: run by run, each in its face.
rich_width :: proc(ctx: ^mu.Context, r: ^Rich, a, b: int) -> i32 {
	if len(r.runs) == 0 {
		return ctx.text_width(ctx.style.font, r.text[a:b])
	}
	w: i32
	i := a
	for i < b {
		run := r.runs[rich_run(r, i)]
		end := min(b, max(run.end, i + 1))
		w += ctx.text_width(rich_font(ctx, run.styles), r.text[i:end])
		i = end
	}
	return w
}

/*
rich_wrap is where the line text[from:to] breaks at `width`, as line_end
and next_line do for plain text: at the last space that fits, or as many
characters as fit if the first word doesn't (but always one); or with
`anywhere`, wherever it has to. text[from:end] is drawn, and the next
line starts at `next`, past the spaces it broke at.
*/
@(private = "file")
rich_wrap :: proc(
	ctx: ^mu.Context,
	r: ^Rich,
	from, to: int,
	width: i32,
	anywhere: bool,
) -> (
	end, next: int,
) {
	text := r.text
	last_space := -1
	fit := from
	w: i32
	end = to
	for i := from; i < to; {
		ch, size := utf8.decode_rune_in_string(text[i:to])
		w += ctx.text_width(rich_font(ctx, rich_styles_at(r, i)), text[i:i + size])
		if w > width && fit > from {
			end = last_space if last_space > from && !anywhere else fit
			break
		}
		fit = i + size
		if ch == ' ' {
			last_space = i
		}
		i += size
	}
	next = end
	if end < to && !anywhere {
		for next < to {
			ch, size := utf8.decode_rune_in_string(text[next:to])
			if !unicode.is_space(ch) {
				break
			}
			next += size
		}
	}
	return
}

// rich_layout lays the text out in lines `width` wide. In the temp
// allocator.
rich_layout :: proc(ctx: ^mu.Context, r: ^Rich, width: i32) -> []Rich_Line {
	out := make([dynamic]Rich_Line, context.temp_allocator)
	for l, li in r.lines {
		x := i32(l.quote) * QUOTE_STEP
		code := l.kind == .Code
		if code {
			x += CODE_PAD
		}
		if l.start == l.end {
			append(&out, Rich_Line{l.start, l.end, x, li})
			continue
		}
		// A list item's lines after its first hang under its text.
		hang: i32
		if l.marker > 0 {
			hang = rich_width(ctx, r, l.start, l.start + l.marker)
		}
		at := l.start
		for first := true; at < l.end; first = false {
			lx := x if first else x + hang
			avail := width - lx - (CODE_PAD if code else 0)
			end, next := rich_wrap(ctx, r, at, l.end, max(avail, 1), code)
			append(&out, Rich_Line{at, end, lx, li})
			at = next
		}
	}
	return out[:]
}

// rich_height is how tall the text is at `width`.
rich_height :: proc(ctx: ^mu.Context, r: ^Rich, width: i32) -> i32 {
	return i32(len(rich_layout(ctx, r, width))) * ctx.text_height(ctx.style.font)
}

// rich_link_id names a link in a message for hovering (UI_Chat.hover):
// the message's item and where the link starts, which stay the same
// from one frame to the next as the text's address doesn't.
@(private = "file")
rich_link_id :: proc(item: i64, start: int) -> uintptr {
	return uintptr(item) << 16 ~ uintptr(start) + 1
}

/*
rich_text draws the text in the current layout, a row a line, which can
be selected as `item`, in `color` but for what's coloured otherwise.
*/
rich_text :: proc(ui: ^UI, r: ^Rich, color: mu.Color, item: i64) {
	ctx := &ui.ctx
	h := ctx.text_height(ctx.style.font)
	select_item(ui, item, r.text)
	width := mu.get_layout(ctx).body.w
	for vl in rich_layout(ctx, r, width) {
		row := mu.layout_next(ctx)
		l := r.lines[vl.line]
		// What's behind the text: a code block's box, quotes' bars.
		if l.kind == .Code {
			qx := i32(l.quote) * QUOTE_STEP
			mu.draw_rect(ctx, {row.x + qx, row.y, row.w - qx, h}, CODE_BLOCK_COLOR)
		}
		for q in 0 ..< l.quote {
			mu.draw_rect(
				ctx,
				{row.x + i32(q) * QUOTE_STEP + QUOTE_BAR_X, row.y, QUOTE_BAR_W, h},
				QUOTE_BAR_COLOR,
			)
		}
		// Then what's behind its pieces, the selection over that, and the
		// pieces.
		pos := mu.Vec2{row.x + vl.x, row.y}
		rich_pieces(ui, r, vl, l.kind == .Code, pos, color, item, .Back)
		select_line(ui, item, r.text, vl.start, vl.end, pos, r)
		rich_pieces(ui, r, vl, l.kind == .Code, pos, color, item, .Front)
		rich_emoji(ui, r, vl, pos)
	}
}

// What rich_pieces draws: the pieces' backgrounds (inline code, a
// mention of the reader), which go under the selection, or the rest.
@(private = "file")
Rich_Pass :: enum {
	Back,
	Front,
}

// rich_pieces draws a line in pieces: where its runs, mentions and links
// begin and end.
@(private = "file")
rich_pieces :: proc(
	ui: ^UI,
	r: ^Rich,
	vl: Rich_Line,
	code_line: bool,
	pos: mu.Vec2,
	color: mu.Color,
	item: i64,
	pass: Rich_Pass,
) {
	ctx := &ui.ctx
	h := ctx.text_height(ctx.style.font)
	cuts := make([dynamic]int, context.temp_allocator)
	cut :: proc(cuts: ^[dynamic]int, vl: Rich_Line, at: int) {
		if at > vl.start && at < vl.end {
			append(cuts, at)
		}
	}
	append(&cuts, vl.start, vl.end)
	for run in r.runs {
		cut(&cuts, vl, run.start)
	}
	for m in r.mentions {
		cut(&cuts, vl, m.start)
		cut(&cuts, vl, m.end)
	}
	for l in r.links {
		cut(&cuts, vl, l.start)
		cut(&cuts, vl, l.end)
	}
	for l in r.msg_links {
		cut(&cuts, vl, l.start)
		cut(&cuts, vl, l.end)
	}
	for l in r.web {
		cut(&cuts, vl, l.start)
		cut(&cuts, vl, l.end)
	}
	slice.sort(cuts[:])

	x := pos.x
	for k in 0 ..< len(cuts) - 1 {
		a, b := cuts[k], cuts[k + 1]
		if a >= b {
			continue
		}
		styles := rich_styles_at(r, a)
		font := rich_font(ctx, styles)
		piece := r.text[a:b]
		w := ctx.text_width(font, piece)
		rect := mu.Rect{x, pos.y, w, h}
		x += w

		// What it is: a link (to the web, a message, or a [text](url)),
		// a mention.
		link_start := -1
		url := ""
		to_message: proto.Msg_Link
		is_message := false
		for l in r.links {
			if l.start <= a && a < l.end {
				link_start, url = l.start, l.url
			}
		}
		for l in r.msg_links {
			if l.start <= a && a < l.end {
				link_start, to_message, is_message = l.start, l.link, true
			}
		}
		for l in r.web {
			if l.start <= a && a < l.end {
				link_start, url = l.start, platform.link_url(r.text, l)
			}
		}
		mention: Maybe(conn.Mention_Span)
		for m in r.mentions {
			if m.start <= a && a < m.end {
				mention = m
			}
		}

		if pass == .Back {
			if .Code in styles && !code_line {
				mu.draw_rect(ctx, {rect.x - 1, rect.y, rect.w + 2, rect.h}, CODE_SPAN_COLOR)
			}
			if m, ok := mention.?; ok && m.me {
				mu.draw_rect(ctx, {rect.x - 1, rect.y, rect.w + 2, rect.h}, MENTION_ME_BACKGROUND)
			}
			continue
		}
		c := color
		if _, ok := mention.?; ok {
			c = MENTION_COLOR
		}
		id: uintptr
		hovered := false
		if link_start >= 0 {
			id = rich_link_id(item, link_start)
			hovered = ui.chat.hover == id
			c = LINK_HOVER_COLOR if hovered else LINK_COLOR
		}
		mu.draw_text(ctx, font, piece, {rect.x, rect.y}, c)
		// Underlined just below the baseline, struck through the middle
		// of the small letters.
		if .Underline in styles || link_start >= 0 {
			mu.draw_rect(ctx, {rect.x, rect.y + h - 2, rect.w, 1}, c)
		}
		if .Strike in styles {
			mu.draw_rect(ctx, {rect.x, rect.y + h * 11 / 20, rect.w, 1}, c)
		}

		if link_start < 0 || !mu.mouse_over(ctx, rect) {
			continue
		}
		ui.chat.hover = id
		ui.chat.hovering = true
		// Where a [text](url) goes isn't in its text: it's said over it.
		for l in r.links {
			if l.start == link_start {
				ui.hint, ui.hint_of = url, rect
			}
		}
		// On the release of a press in this panel, and only if that
		// didn't end a drag that selected something (ui_select.odin).
		if .LEFT in ctx.mouse_released_bits &&
		   ui.select.dragging &&
		   ui.select.panel == ui.select.drawing &&
		   !has_selection(&ui.select, ui.select.drawing) &&
		   ui.chat.open == "" {
			if is_message {
				ui.forward.go_conv, ui.forward.go_id = to_message.conv, to_message.id
			} else {
				ui.chat.open = fmt.aprint(url)
			}
		}
	}
}

// rich_emoji draws the server's emoji over their placeholders in a line,
// and names the one under the pointer, as emoji_hint does.
@(private = "file")
rich_emoji :: proc(ui: ^UI, r: ^Rich, vl: Rich_Line, pos: mu.Vec2) {
	ctx := &ui.ctx
	h := ctx.text_height(ctx.style.font)
	for e in r.emoji {
		if e.start < vl.start || e.start >= vl.end {
			continue
		}
		icon, ok := custom_emoji_icon(ui, e.index)
		if !ok {
			continue
		}
		x := pos.x + rich_width(ctx, r, vl.start, e.start)
		size, advance := custom_emoji_size(ctx)
		gap := (advance - size) / 2
		mu.draw_icon(
			ctx,
			icon,
			{x + gap, pos.y + (h - size) / 2, size, size},
			{255, 255, 255, 255},
		)
	}

	line := mu.Rect{pos.x, pos.y, rich_width(ctx, r, vl.start, vl.end), h}
	if !mu.mouse_over(ctx, line) {
		return
	}
	mouse := ctx.mouse_pos.x
	x := pos.x
	for i := vl.start; i < vl.end; {
		ch, size := utf8.decode_rune_in_string(r.text[i:vl.end])
		w := rich_width(ctx, r, i, i + size)
		if mouse >= x && mouse < x + w {
			name := ""
			for e in r.emoji {
				if e.start == i && e.index < len(ui.view.emoji.names) {
					name = ui.view.emoji.names[e.index]
				}
			}
			if name == "" {
				if index, is := proto.emoji_index(ch); is {
					name = proto.emoji_name(proto.EMOJI[index])
				}
			}
			if name != "" {
				ui.hint, ui.hint_of = fmt.tprintf(":%s:", name), mu.Rect{x, pos.y, w, h}
			}
			return
		}
		x += w
		i += size
	}
}
