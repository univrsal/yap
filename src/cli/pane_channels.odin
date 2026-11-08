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
	Voice_User, // someone in the voice room of the channel above
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
	// A channel's voice room: whether it has one, whether we are in it; or for a
	// Voice_User, how they are.
	voice:    bool,
	in_room:  bool,
	user:     Voice_User,
}

// list_rows is what the list shows, in order. Call with the View locked.
list_rows :: proc(v: ^conn.View) -> []List_Row {
	rows := make([dynamic]List_Row, context.temp_allocator)
	append(&rows, List_Row{kind = .Header, name = "Channels"})
	for ch in v.channels {
		append(
			&rows,
			List_Row {
				kind = .Channel,
				conv = ch.id,
				name = ch.name,
				unread = ch.unread,
				mentions = ch.mentions,
				voice = has_voice(ch),
				in_room = ch.id == v.my_room,
			},
		)
		for u in voice_users(v, ch) {
			append(&rows, List_Row{kind = .Voice_User, conv = ch.id, name = u.name, user = u})
		}
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
			if num != v.my_num &&
			   (u.account == dm.with || slice.contains(conn.group_members(&dm), u.account)) {
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
		if r.kind != .Header && r.kind != .Voice_User {
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
	append(&a.hits, Hit{g.border, .Border, 0, ""})

	// The server.
	tui.fill(b, {r.x, 0, r.w, 1}, theme.bar)
	name := v.server_name if v.server_name != "" else v.server
	tui.put_string(
		b,
		r.x + 1,
		0,
		name,
		{fg = theme.bar.fg, bg = theme.bar.bg, attrs = {.Bold}},
		r.x + r.w - 1,
	)

	// With several servers they are listed first.
	rail := rail_height(a)
	draw_rail(a, b, {r.x, 1, r.w, rail})

	rows := list_rows(v)
	visible := r.h - 1 - rail
	a.chan_scroll = clamp(a.chan_scroll, 0, max(len(rows) - visible, 0))
	y := 1 + rail
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
		if row.kind == .Voice_User {
			style :=
				tui.Style{fg = theme.online.fg, attrs = {.Bold}} if row.user.speaking else theme.dim
			mark := "▸ "
			text := row.name
			if row.user.deafened {
				text = fmt.tprintf("%s (deaf)", row.name)
			} else if row.user.muted {
				text = fmt.tprintf("%s (muted)", row.name)
			}
			tui.put_string(b, r.x + 4, y, mark, style, r.x + r.w)
			tui.put_string(b, r.x + 6, y, tui.cut_to_width(text, r.w - 7), style, r.x + r.w)
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
		case .Header, .Channel, .Voice_User:
		}
		tui.put_string(b, r.x + 1, y, mark, mark_style, r.x + r.w)
		// The voice room's door, a click of its own, on top of the row's.
		door_hit: Maybe(Hit)
		if row.voice && row.kind == .Channel {
			name_w -= 2
			door :=
				tui.Style{fg = theme.online.fg, bg = style.bg, attrs = {.Bold}} if row.in_room else tui.Style{fg = theme.dim.fg, bg = style.bg}
			dx := r.x + 3 + min(tui.string_width(row.name), name_w) + 1
			tui.put_string(b, dx, y, "♪", door, r.x + r.w)
			door_hit = Hit{{dx - 1, y, 3, 1}, .Voice_Join, u64(row.conv), ""}
		}
		tui.put_string(b, r.x + 3, y, tui.cut_to_width(row.name, name_w), name_style, r.x + r.w)
		if badge_w > 0 {
			tui.put_string(b, r.x + r.w - badge_w - 1, y, badge, badge_style)
		}
		append(&a.hits, Hit{{r.x, y, r.w, 1}, .Channel, u64(row.conv), ""})
		if door, has := door_hit.?; has {
			append(&a.hits, door)
		}
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
