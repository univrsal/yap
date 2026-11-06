package main

import "core:fmt"
import "core:slice"

import "client:conn"
import "common:proto"
import "tui"

// The channel list on the left: the server's name, our channels, and the DMs and
// groups we have written in, each with what is unread in it. Click one to
// look at it.

List_Row_Kind :: enum {
	Header,
	Channel,
	Direct, // a DM
	Group,
}

List_Row :: struct {
	kind:     List_Row_Kind,
	conv:     proto.Conv_Id,
	name:     string, // in the temp allocator
	unread:   int,
	mentions: int,
	online:   bool,
}

// list_rows is what the list shows, in order. Call with the View locked.
list_rows :: proc(v: ^conn.View) -> []List_Row {
	rows := make([dynamic]List_Row, context.temp_allocator)
	append(&rows, List_Row{kind = .Header, name = "Channels"})
	for ch in v.channels {
		append(&rows, List_Row{kind = .Channel, conv = ch.id, name = ch.name, unread = ch.unread, mentions = ch.mentions})
	}
	// DMs and groups that have had something said in them, newest first. The one
	// with ourselves is the notes, and is not here.
	dms := make([dynamic]conn.View_DM, context.temp_allocator)
	for dm in v.dms {
		if dm.count == 0 && dm.with == v.me {
			continue
		}
		if dm.last == 0 && dm.unread == 0 {
			continue
		}
		append(&dms, dm)
	}
	slice.sort_by(dms[:], proc(a, b: conn.View_DM) -> bool {
		return a.last_time > b.last_time
	})
	if len(dms) > 0 {
		append(&rows, List_Row{kind = .Header, name = "Direct messages"})
	}
	for &dm in dms {
		online := false
		for num, u in v.users {
			if num != v.my_num && (u.account == dm.with || slice.contains(conn.group_members(&dm), u.account)) {
				online = true
				break
			}
		}
		append(
			&rows,
			List_Row {
				kind = .Group if dm.count > 0 else .Direct,
				conv = dm.id,
				name = conn.dm_name(v, &dm),
				unread = dm.unread,
				mentions = dm.mentions,
				online = online,
			},
		)
	}
	return rows[:]
}

// conversations_in_order are the ids of what the list shows, for switching with
// the keys. Call with the View locked.
conversations_in_order :: proc(v: ^conn.View) -> []proto.Conv_Id {
	out := make([dynamic]proto.Conv_Id, context.temp_allocator)
	for r in list_rows(v) {
		if r.kind != .Header {
			append(&out, r.conv)
		}
	}
	return out[:]
}

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

	rows := list_rows(v)
	visible := r.h - 1
	a.chan_scroll = clamp(a.chan_scroll, 0, max(len(rows) - visible, 0))
	y := 1
	for row, i in rows {
		if i < a.chan_scroll {
			continue
		}
		if y >= r.y + r.h {
			break
		}
		if row.kind == .Header {
			tui.put_string(b, r.x + 1, y, row.name, theme.dim, r.x + r.w)
			y += 1
			continue
		}
		picked := row.conv == v.viewing
		style := theme.selected if picked else tui.Style{}
		tui.fill(b, {r.x, y, r.w, 1}, style)
		// The badge is at the right, the name takes what is left.
		badge, badge_style := channel_badge(row.unread, row.mentions)
		badge_w := tui.string_width(badge)
		name_w := r.w - 3 - (badge_w + 1 if badge_w > 0 else 0)
		name_style := style
		if row.unread > 0 && !picked {
			name_style.attrs += {.Bold}
		}
		mark, mark_style := "#", style if picked else theme.dim
		switch row.kind {
		case .Direct:
			mark = "●" if row.online else "○"
			mark_style = style if picked else (theme.online if row.online else theme.dim)
		case .Group:
			mark = "◆"
		case .Header, .Channel:
		}
		tui.put_string(b, r.x + 1, y, mark, mark_style, r.x + r.w)
		tui.put_string(b, r.x + 3, y, tui.cut_to_width(row.name, name_w), name_style, r.x + r.w)
		if badge_w > 0 {
			tui.put_string(b, r.x + r.w - badge_w - 1, y, badge, badge_style)
		}
		append(&a.hits, Hit{{r.x, y, r.w, 1}, .Channel, u64(row.conv)})
		y += 1
	}
}

// channel_badge is what is unread in a conversation as the list shows it: the
// number of messages, or "@" and the number of mentions of us.
channel_badge :: proc(unread, mentions: int) -> (text: string, style: tui.Style) {
	switch {
	case mentions > 0:
		return fmt.tprintf(" @%d ", mentions), theme.badge_ping
	case unread > 0:
		return fmt.tprintf(" %d ", unread), theme.badge
	}
	return "", {}
}

