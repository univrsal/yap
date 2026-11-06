package main

import "core:fmt"

import "client:conn"
import "tui"

// The channel list on the left: the server's name, then our channels with what
// is unread in them. Click one to look at it.

draw_channels :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	r := g.channels
	if r.w == 0 {
		return
	}
	v := a.view
	// The border is a place to grab.
	for y in 0 ..< g.border.h {
		tui.set_cell(b, g.border.x, y, '│', 1, theme.border)
	}
	append(&a.hits, Hit{g.border, .Border, 0})

	// The server.
	tui.fill(b, {r.x, 0, r.w, 1}, theme.bar)
	name := v.server_name if v.server_name != "" else v.server
	tui.put_string(b, r.x + 1, 0, name, {fg = theme.bar.fg, bg = theme.bar.bg, attrs = {.Bold}}, r.x + r.w - 1)

	y := 1
	tui.put_string(b, r.x + 1, y, "Channels", theme.dim, r.x + r.w)
	y += 1
	rows := r.h - y
	a.chan_scroll = clamp(a.chan_scroll, 0, max(len(v.channels) - rows, 0))
	for ch, i in v.channels {
		if i < a.chan_scroll {
			continue
		}
		if y >= r.y + r.h {
			break
		}
		style := theme.selected if ch.id == v.viewing else tui.Style{}
		tui.fill(b, {r.x, y, r.w, 1}, style)
		// The badge is at the right, the name takes what is left.
		badge, badge_style := channel_badge(ch)
		badge_w := tui.string_width(badge)
		name_w := r.w - 3 - (badge_w + 1 if badge_w > 0 else 0)
		name_style := style
		if ch.unread > 0 && ch.id != v.viewing {
			name_style.attrs += {.Bold}
		}
		tui.put_string(b, r.x + 1, y, "#", style if ch.id == v.viewing else theme.dim, r.x + r.w)
		tui.put_string(b, r.x + 3, y, tui.cut_to_width(ch.name, name_w), name_style, r.x + r.w)
		if badge_w > 0 {
			tui.put_string(b, r.x + r.w - badge_w - 1, y, badge, badge_style)
		}
		append(&a.hits, Hit{{r.x, y, r.w, 1}, .Channel, u64(ch.id)})
		y += 1
	}
}

// channel_badge is what is unread in a channel as the list shows it: the number
// of messages, or "@" and the number of mentions of us.
channel_badge :: proc(ch: conn.View_Channel) -> (text: string, style: tui.Style) {
	switch {
	case ch.mentions > 0:
		return fmt.tprintf(" @%d ", ch.mentions), theme.badge_ping
	case ch.unread > 0:
		return fmt.tprintf(" %d ", ch.unread), theme.badge
	}
	return "", {}
}
