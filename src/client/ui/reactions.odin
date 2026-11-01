package ui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:richtext"
import "common:proto"

// A message's reactions are a row of chips under it, each with its emoji and
// how many reacted with it, with ours highlighted. They wrap onto more rows
// when the width runs out. Clicking one adds or removes our reaction.
// reactions_height has to agree with reaction_chips.
@(private = "file")
Chip :: struct {
	r:     conn.Reaction,
	text:  string, // the emoji as shown, followed by the count
	icons: []richtext.Emoji_Span, // the server's emoji in it
	w:     i32,
}

// The gap above the chips, and their height (logical pixels).
@(private = "file")
CHIPS_GAP :: 3
@(private = "file")
chip_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.text_height(ctx.style.font) + 6
}

// reaction_rows lays a message's chips out in rows at `width`.
@(private = "file")
reaction_rows :: proc(ui: ^UI, m: conn.View_Message, width: i32) -> [][dynamic]Chip {
	ctx := &ui.ctx
	rows := make([dynamic][dynamic]Chip, context.temp_allocator)
	x := width + 1
	for r in m.reactions {
		code := fmt.tprintf("%s %d", r.emoji, r.count)
		shown, _, icons := richtext.text_display(
			code,
			map[proto.Account_Id]conn.View_Account{},
			nil,
			0,
			ui.view.emoji.names[:],
		)
		w := ctx.text_width(ctx.style.font, shown) + 12
		if x + w > width && x > 0 {
			append(&rows, make([dynamic]Chip, context.temp_allocator))
			x = 0
		}
		append(&rows[len(rows) - 1], Chip{r, shown, icons, w})
		x += w + ctx.style.spacing
	}
	return rows[:]
}

reactions_height :: proc(ui: ^UI, m: conn.View_Message, width: i32) -> i32 {
	if len(m.reactions) == 0 || .Deleted in m.flags {
		return 0
	}
	ctx := &ui.ctx
	rows := i32(len(reaction_rows(ui, m, width)))
	return CHIPS_GAP + ctx.style.spacing + rows * (chip_height(ctx) + ctx.style.spacing)
}

reaction_chips :: proc(ui: ^UI, m: conn.View_Message, width: i32, readonly := false) {
	if len(m.reactions) == 0 || .Deleted in m.flags {
		return
	}
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, CHIPS_GAP)
	mu.layout_next(ctx)
	h := chip_height(ctx)
	mu.push_id(ctx, uintptr(m.id))
	defer mu.pop_id(ctx)
	for row, ri in reaction_rows(ui, m, width) {
		widths := make([]i32, len(row), context.temp_allocator)
		for c, i in row {
			widths[i] = c.w
		}
		mu.layout_row(ctx, widths, h)
		for c, i in row {
			mu.push_id(ctx, uintptr(ri * proto.MAX_REACTIONS + i))
			id := mu.get_id(ctx, "chip")
			rect := mu.layout_next(ctx)
			mu.update_control(ctx, id, rect)
			keyed := !readonly && nav_control(ctx, id, rect)
			background := theme.track
			switch {
			case c.r.me:
				background = theme.highlight
			case ctx.hover_id == id:
				background = ctx.style.colors[.BUTTON_HOVER]
			}
			if ctx.hover_id == id && c.r.me {
				background = theme.highlight_more
			}
			render.draw_rounded(ctx, rect, background, render.CONTROL_RADIUS)
			font := ctx.style.font
			pos := mu.Vec2{rect.x + 6, rect.y + (rect.h - ctx.text_height(font)) / 2}
			mu.draw_text(ctx, font, c.text, pos, ctx.style.colors[.TEXT])
			draw_chip_emoji(ui, c, pos)
			if ctx.hover_id == id {
				reactors_hint(ui, m.id, c.r, rect)
			}
			if !readonly && ctx.hover_id == id && ctx.mouse_pressed_bits == {.LEFT} || keyed {
				send_reaction(ui, m.id, c.r.emoji, !c.r.me)
			}
			mu.pop_id(ctx)
		}
	}
}

// Who reacted, as last requested (reactors_hint): not requested again while
// it is the same message, emoji and count.
Reactors_Asked :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned
	count: int,
}

// How many names a reaction's hint lists, and how many per line.
@(private = "file")
REACTORS_SHOWN :: 15
@(private = "file")
REACTORS_PER_LINE :: 5

// reactors_hint is the hint above a reaction: the emoji's :name:, and who
// reacted with it ("you" for us), the first REACTORS_SHOWN and how many more.
// Who it was is requested from the server the first time the pointer is on
// it, and again when the count has changed.
@(private = "file")
reactors_hint :: proc(ui: ^UI, id: proto.Msg_Id, r: conn.Reaction, rect: mu.Rect) {
	v := ui.view
	asked := &ui.reactors_asked
	name := r.emoji
	if !strings.has_prefix(name, ":") {
		first, _ := utf8.decode_rune_in_string(r.emoji)
		if index, ok := proto.emoji_index(first); ok {
			name = fmt.tprintf(":%s:", proto.emoji_name(proto.EMOJI[index]))
		}
	}
	have := v.reactors.id == id && v.reactors.emoji == r.emoji && v.reactors.total == r.count
	hint_emoji_of(ui, r.emoji)
	if !have &&
	   (asked.id != id || asked.emoji != r.emoji || asked.count != r.count) &&
	   ui.session != nil {
		delete(asked.emoji)
		asked^ = {id, strings.clone(r.emoji), r.count}
		conn.push_command(
			&ui.session.client.commands,
			conn.Reactors_Command{id = id, emoji = strings.clone(r.emoji)},
		)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, name)
	if !have {
		strings.write_string(&b, "\n...")
		ui.hint, ui.hint_of = strings.to_string(b), rect
		return
	}
	shown := min(len(v.reactors.accounts), REACTORS_SHOWN)
	for account, i in v.reactors.accounts[:shown] {
		strings.write_string(&b, "\n" if i % REACTORS_PER_LINE == 0 else ", ")
		switch {
		case account == v.me:
			strings.write_string(&b, "you")
		case account in v.accounts:
			strings.write_string(&b, v.accounts[account].display)
		case:
			strings.write_string(&b, "someone")
		}
	}
	if more := v.reactors.total - shown; more > 0 {
		fmt.sbprintf(&b, "\nand %d more", more)
	}
	ui.hint, ui.hint_of = strings.to_string(b), rect
}

// draw_chip_emoji draws the server's emoji over their placeholders in a chip's
// text, drawn at `pos`.
@(private = "file")
draw_chip_emoji :: proc(ui: ^UI, c: Chip, pos: mu.Vec2) {
	ctx := &ui.ctx
	for e in c.icons {
		icon, ok := custom_emoji_icon(ui, e.index)
		if !ok {
			continue
		}
		x := pos.x + ctx.text_width(ctx.style.font, c.text[:e.start])
		size, advance := custom_emoji_size(ctx)
		gap := (advance - size) / 2
		y := pos.y + (ctx.text_height(ctx.style.font) - size) / 2
		mu.draw_icon(ctx, icon, {x + gap, y, size, size}, {255, 255, 255, 255})
	}
}
