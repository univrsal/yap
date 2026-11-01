package ui

import "core"
import "widgets"
import "core:strings"
import "client:render"
import mu "vendor:microui"

// hint_emoji_of makes the hint show `emoji` large: a reaction's or
// message's emoji, ":name:" for the server's, else the characters. Call with
// the View locked.
hint_emoji_of :: proc(env: ^core.Env, emoji: string) {
	if strings.has_prefix(emoji, ":") && strings.has_suffix(emoji, ":") && len(emoji) > 2 {
		name := emoji[1:len(emoji) - 1]
		for n, i in env.view.emoji.names {
			if n == name {
				env.hint_emoji = {
					custom = i,
				}
				return
			}
		}
		return
	}
	env.hint_emoji = {
		unicode = emoji,
	}
}

icon_hint :: proc(ui: ^UI, window_w, window_h: i32) {
	ctx := &ui.ctx
	emoji := ui.hint_emoji
	defer ui.hint, ui.hint_emoji = "", {}
	// The pointer under a scrolling finger describes nothing.
	if ui.hint == "" || ui.touch_scrolling {
		return
	}

	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	w, lines: i32
	rest := ui.hint
	for line in strings.split_lines_iterator(&rest) {
		w = max(w, ctx.text_width(ctx.style.font, line))
		lines += 1
	}
	// The emoji, large, above the text.
	big_w, big_h: i32
	if _, custom := emoji.custom.?; custom || emoji.unicode != "" {
		big_h = ctx.text_height(render.PREVIEW_FONT)
		big_w = big_h
		if !custom {
			big_w = ctx.text_width(render.PREVIEW_FONT, emoji.unicode)
		}
		w = max(w, big_w)
	}
	w += 2 * pad
	h := lines * line_h + 2 * pad
	if big_h > 0 {
		h += big_h + pad
	}
	// Under the button, moved left if it would go off the side, and
	// above it if there is no room below (the chat box's Send button).
	x := min(ui.hint_of.x, max(window_w - w, 0))
	y := ui.hint_of.y + ui.hint_of.h + 2
	if y + h > window_h {
		y = max(ui.hint_of.y - h - 2, 0)
	}
	r := mu.Rect{x, y, w, h}
	// The pointer is on the button, never on the hint, so the window
	// doesn't take the hover away from the thing it describes.
	cnt := mu.get_container(ctx, widgets.HINT_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(
		ctx,
		widgets.HINT_WINDOW,
		r,
		{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT},
	) {
		return
	}
	defer mu.end_window(ctx)
	render.draw_rounded(ctx, r, ctx.style.colors[.BASE], render.CONTROL_RADIUS)
	render.draw_rounded_border(ctx, r, ctx.style.colors[.BORDER], render.CONTROL_RADIUS)
	line_y := y + pad
	if big_h > 0 {
		at := mu.Vec2{x + (w - big_w) / 2, line_y}
		if index, custom := emoji.custom.?; custom {
			if icon, ok := custom_emoji_icon(ui, index); ok {
				mu.draw_icon(ctx, icon, {at.x, at.y, big_w, big_h}, {255, 255, 255, 255})
			}
		} else {
			mu.draw_text(ctx, render.PREVIEW_FONT, emoji.unicode, at, ctx.style.colors[.TEXT])
		}
		line_y += big_h + pad
	}
	rest = ui.hint
	for line in strings.split_lines_iterator(&rest) {
		mu.draw_text(ctx, ctx.style.font, line, {x + pad, line_y}, ctx.style.colors[.TEXT])
		line_y += line_h
	}
}
