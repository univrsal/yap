package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:conn"
import "common:proto"
import "tui"

// The list on the right: who is in the conversation, those who are here first.
// Click someone to write to them.

Member_Row :: struct {
	account:  proto.Account_Id,
	name:     string,
	status:   string,
	activity: proto.Activity,
	online:   bool,
	admin:    bool,
}

// member_rows are the members of the conversation shown, online ones first and
// each group by name. It is empty until the server has answered. Call with the
// View locked.
member_rows :: proc(v: ^conn.View) -> (rows: []Member_Row, loading: bool) {
	if v.members.conv != v.viewing || v.viewing == 0 {
		return nil, true
	}
	list := make([dynamic]Member_Row, context.temp_allocator)
	for id in v.members.accounts {
		row := Member_Row {
			account = id,
			name    = "someone",
		}
		if acc, ok := v.accounts[id]; ok {
			row.name, row.status, row.activity = acc.display, acc.status, acc.activity
			if .Deleted in acc.flags {
				continue
			}
		}
		for num, u in v.users {
			if u.account == id && num != v.my_num || id == v.me {
				row.online = true
				break
			}
		}
		row.admin = slice.contains(v.members.admins[:], id)
		append(&list, row)
	}
	slice.sort_by(list[:], proc(a, b: Member_Row) -> bool {
		if a.online != b.online {
			return a.online
		}
		an := strings.to_lower(a.name, context.temp_allocator)
		bn := strings.to_lower(b.name, context.temp_allocator)
		return an < bn
	})
	return list[:], v.members.loading
}

// activity_mark is the mark in front of a name and its colour.
activity_mark :: proc(m: Member_Row) -> (string, tui.Style) {
	if !m.online || m.activity == .Offline {
		return "○", theme.dim
	}
	switch m.activity {
	case .Away: return "●", {fg = tui.color_index(214)}
	case .Busy: return "●", {fg = tui.color_index(203)}
	case .Online, .Offline: return "●", theme.online
	}
	return "●", theme.online
}

draw_members :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	r := g.members
	if r.w == 0 {
		return
	}
	for y in 0 ..< g.members_border.h {
		tui.set_cell(b, g.members_border.x, y, '│', 1, theme.border)
	}
	tui.fill(b, {r.x, 0, r.w, 1}, theme.bar)
	rows, loading := member_rows(a.view)
	online := 0
	for m in rows {
		online += 1 if m.online else 0
	}
	title := "Members" if loading && len(rows) == 0 else fmt.tprintf("Members  %d/%d", online, len(rows))
	tui.put_string(b, r.x + 1, 0, title, {fg = theme.bar.fg, bg = theme.bar.bg, attrs = {.Bold}}, r.x + r.w)

	visible := r.h - 1
	a.members_scroll = clamp(a.members_scroll, 0, max(len(rows) - visible, 0))
	y := 1
	for m, i in rows {
		if i < a.members_scroll {
			continue
		}
		if y >= r.y + r.h {
			break
		}
		mark, mark_style := activity_mark(m)
		tui.put_string(b, r.x + 1, y, mark, mark_style, r.x + r.w)
		style := tui.Style{} if m.online else theme.dim
		name := m.name
		if m.admin {
			name = fmt.tprintf("%s ★", name)
		}
		tui.put_string(b, r.x + 3, y, tui.cut_to_width(name, r.w - 4), style, r.x + r.w)
		append(&a.hits, Hit{{r.x, y, r.w, 1}, .Member, u64(m.account), ""})
		y += 1
	}
}
