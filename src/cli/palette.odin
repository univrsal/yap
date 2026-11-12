package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "client:conn"
import "common:proto"
import "tui"

// The command palette (Ctrl+K): type a few letters of where to go or what to do.
// It lists the conversations, the servers and the things that have a command,
// and does the one chosen.

Palette_Kind :: enum {
	Conversation,
	Server,
	Command, // a /command line, run as if typed
	Call, // call a person; index is their account
	Form, // a form (see forms.odin); arg is its Form_Kind
}

Palette_Item :: struct {
	label: string, // in the temp allocator
	kind:  Palette_Kind,
	conv:  proto.Conv_Id,
	index: int, // a server's, or a form's
	line:  string, // the command
}

open_palette :: proc(a: ^App) {
	dialog_close(a)
	a.dialog.kind, a.dialog.sel = .Palette, 0
}

// palette_items are all the things on offer, in the order they are shown when
// nothing is typed. Call with the View locked.
palette_items :: proc(a: ^App) -> []Palette_Item {
	v := a.view
	items := make([dynamic]Palette_Item, context.temp_allocator)
	for row in list_rows(v) {
		switch row.kind {
		case .Channel:
			append(
				&items,
				Palette_Item {
					label = fmt.tprintf("# %s", row.name),
					kind = .Conversation,
					conv = row.conv,
				},
			)
		case .Direct, .Group:
			append(
				&items,
				Palette_Item {
					label = fmt.tprintf("@ %s", row.name),
					kind = .Conversation,
					conv = row.conv,
				},
			)
		case .Header, .Voice_User:
		}
	}
	if len(a.servers) > 1 {
		for s, i in a.servers {
			name := server_name(a.view) if i == a.cur else s.target.server
			append(
				&items,
				Palette_Item{label = fmt.tprintf("Server: %s", name), kind = .Server, index = i},
			)
		}
	}
	// People who can be called: those we have a DM with, and those who are here.
	callable := make(map[proto.Account_Id]bool, context.temp_allocator)
	for dm in v.dms {
		if dm.count == 0 && dm.with != v.me {
			callable[dm.with] = true
		}
	}
	for num, u in v.users {
		if num != v.my_num {
			callable[u.account] = true
		}
	}
	people := make([dynamic]proto.Account_Id, context.temp_allocator)
	for id in callable {
		if can_call(a, id) {
			append(&people, id)
		}
	}
	slice.sort(people[:])
	for id in people {
		append(
			&items,
			Palette_Item {
				label = fmt.tprintf("Call %s", v.accounts[id].display),
				kind = .Call,
				index = int(id),
			},
		)
	}
	command :: proc(items: ^[dynamic]Palette_Item, label, line: string) {
		append(items, Palette_Item{label = label, kind = .Command, line = line})
	}
	command(&items, "Join or leave the voice room", "/voice")
	command(&items, "Mute" if !a.muted else "Unmute", "/mute" if !a.muted else "/unmute")
	command(
		&items,
		"Deafen" if !a.deafened else "Stop being deaf",
		"/deafen" if !a.deafened else "/undeafen",
	)
	if a.view.viewing != 0 {
		here := viewed_name(a)
		for line, level in ([proto.Notify_Level]string{.All = "all", .Mentions = "mentions", .None = "none"}) {
			mark := "  (now)" if viewed_notify(a.view) == level else ""
			command(
				&items,
				fmt.tprintf("Notifications for %s: %s%s", here, notify_text(level), mark),
				fmt.tprintf("/notify %s", line),
			)
		}
	}
	command(&items, "Insert an emoji", "/emoji")
	command(&items, "Settings", "/settings")
	command(&items, "Search messages", "/search")
	command(&items, "Pinned messages", "/pins")
	command(&items, "Bookmarks", "/bookmarks")
	command(&items, "Roles", "/roles")
	command(&items, "Bans", "/bans")
	command(&items, "Invites", "/invites")
	command(&items, "Your devices", "/devices")
	command(&items, "Servers", "/servers")
	if len(a.servers) > 1 {
		for s, i in a.servers {
			name := server_name(a.view) if i == a.cur else s.target.server
			append(
				&items,
				Palette_Item {
					label = fmt.tprintf("Disconnect and forget: %s", name),
					kind = .Command,
					line = fmt.tprintf("/disconnect %d", i + 1),
				},
			)
		}
	}
	for kind in Form_Kind {
		append(&items, Palette_Item{label = FORM_TITLES[kind], kind = .Form, index = int(kind)})
	}
	command(&items, "Help", "/help")
	command(&items, "Quit", "/quit")
	return items[:]
}

// palette_match says how well the typed letters match a label: 0 for not at
// all, higher the better. All the letters have to be there in order; the start
// of the label or of a word counts for more, and a run of them for more still.
palette_match :: proc(label, typed: string) -> int {
	if typed == "" {
		return 1
	}
	l := strings.to_lower(label, context.temp_allocator)
	q := strings.to_lower(typed, context.temp_allocator)
	score := 0
	at := 0
	prev := -2
	for r in q {
		if r == ' ' {
			continue
		}
		found := strings.index_rune(l[at:], r)
		if found < 0 {
			return 0
		}
		pos := at + found
		score += 1
		if pos == prev + 1 {
			score += 3 // a run
		}
		if pos == 0 || l[pos - 1] == ' ' || l[pos - 1] == '#' || l[pos - 1] == '@' {
			score += 4 // the start of a word
		}
		prev = pos
		at = pos + 1
	}
	if strings.contains(l, strings.trim_space(q)) {
		score += 10
	}
	return score
}

// palette_shown are the items that match what is typed, best first.
palette_shown :: proc(a: ^App) -> []Palette_Item {
	typed := tui.editor_text(&a.dialog.fields[0])
	all := palette_items(a)
	Scored :: struct {
		item:  Palette_Item,
		score: int,
		order: int,
	}
	scored := make([dynamic]Scored, context.temp_allocator)
	for it, i in all {
		if s := palette_match(it.label, typed); s > 0 {
			append(&scored, Scored{it, s, i})
		}
	}
	if typed != "" {
		slice.stable_sort_by(scored[:], proc(x, y: Scored) -> bool {return x.score > y.score})
	}
	out := make([]Palette_Item, len(scored), context.temp_allocator)
	for s, i in scored {
		out[i] = s.item
	}
	return out
}

PALETTE_ROWS :: 10

draw_palette :: proc(a: ^App, b: ^tui.Buffer) {
	d := &a.dialog
	w := min(b.w - 4, 64)
	items := palette_shown(a)
	d.sel = clamp(d.sel, 0, max(len(items) - 1, 0))
	rows := min(len(items), PALETTE_ROWS)
	h := rows + 4
	r := tui.Rect{(b.w - w) / 2, min(2, max(b.h - h, 0)), w, min(h, b.h)}
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, "Go to / do")
	text := tui.editor_text(&d.fields[0])
	tui.put_string(b, r.x + 2, r.y + 1, "> ", theme.dim)
	tui.put_string(b, r.x + 4, r.y + 1, tui.cut_to_width(text, r.w - 7), {}, r.x + r.w - 1)
	a.cursor, a.cursor_shown = {r.x + 4 + min(tui.string_width(text), r.w - 7), r.y + 1}, true
	top := clamp(d.sel - rows + 1, 0, max(len(items) - rows, 0))
	for i in top ..< min(top + rows, len(items)) {
		y := r.y + 2 + i - top
		style := theme.selected if i == d.sel else tui.Style{}
		tui.fill(b, {r.x + 1, y, r.w - 2, 1}, style)
		tui.put_string(
			b,
			r.x + 2,
			y,
			tui.cut_to_width(items[i].label, r.w - 4),
			style,
			r.x + r.w - 1,
		)
		append(&a.hits, Hit{{r.x + 1, y, r.w - 2, 1}, .Palette_Item, u64(i), ""})
	}
	if len(items) == 0 {
		tui.put_string(b, r.x + 2, r.y + 2, "Nothing matches.", theme.dim, r.x + r.w - 1)
	}
}

palette_key :: proc(a: ^App, k: tui.Key_Event) {
	d := &a.dialog
	items := palette_shown(a)
	switch {
	case k.key == .Escape:
		dialog_close(a)
	case k.key == .Up:
		d.sel = max(d.sel - 1, 0)
	case k.key == .Down, k.key == .Tab:
		d.sel = min(d.sel + 1, max(len(items) - 1, 0))
	case k.key == .Enter:
		palette_choose(a, d.sel)
	case:
		if tui.editor_key(&d.fields[0], k) {
			d.sel = 0
		}
	}
}

palette_choose :: proc(a: ^App, i: int) {
	items := palette_shown(a)
	if i < 0 || i >= len(items) {
		return
	}
	it := items[i]
	line := strings.clone(it.line, context.temp_allocator)
	dialog_close(a)
	switch it.kind {
	case .Conversation:
		push(a, conn.View_Command{conv = it.conv})
	case .Server:
		app_switch(a, it.index)
	case .Command:
		run_command(a, line)
	case .Call:
		start_call(a, proto.Account_Id(it.index))
	case .Form:
		open_form(a, Form_Kind(it.index))
	}
}
