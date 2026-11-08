package main

import "core:fmt"
import "core:strings"

import "client:conn"
import "common:proto"
import "tui"

// Lists of messages that are found elsewhere than in the timeline: the pinned
// ones, the bookmarked ones and the results of a search. They are shown in a
// dialog, from the View as it changes, and choosing one goes to the message.

List_Kind :: enum {
	Pins,
	Bookmarks,
	Search,
}

List_Entry :: struct {
	conv: proto.Conv_Id,
	msg:  ^conn.View_Message,
}

// list_entries are the messages the dialog shows. Call with the View locked.
list_entries :: proc(a: ^App) -> []List_Entry {
	v := a.view
	out := make([dynamic]List_Entry, context.temp_allocator)
	switch a.dialog.list {
	case .Pins:
		if v.pins.conv == v.viewing {
			for &m in v.pins.messages {
				append(&out, List_Entry{v.pins.conv, &m})
			}
		}
	case .Bookmarks:
		for &b in v.bookmarks.list {
			append(&out, List_Entry{b.conv, &b.msg})
		}
	case .Search:
		for &f in v.search.found {
			append(&out, List_Entry{f.conv, &f.msg})
		}
	}
	return out[:]
}

// open_list opens the dialog for pinned messages, bookmarks or a search, and
// asks for what it shows.
open_list :: proc(a: ^App, kind: List_Kind, query := "") {
	dialog_close(a)
	a.dialog.kind, a.dialog.list = .List, kind
	switch kind {
	case .Pins:
		push(a, conn.Pins_Command{conv = a.viewing})
	case .Bookmarks:
		push(a, conn.Bookmarks_Command{})
	case .Search:
		if query != "" {
			tui.editor_set(&a.dialog.fields[0], query)
			run_search(a)
		}
	}
}

list_close :: proc(a: ^App) {
	if a.dialog.kind == .List && a.dialog.list == .Bookmarks {
		push(a, conn.Bookmarks_Command{close = true})
	}
}

run_search :: proc(a: ^App) {
	query := strings.trim_space(tui.editor_text(&a.dialog.fields[0]))
	if query == "" {
		return
	}
	push(a, conn.Search_Command{query = strings.clone(query), all = a.dialog.all})
	a.dialog.sel = 0
	a.dialog.field = 1 // the results
}

// conversation_name is what a conversation is called in a list. Call with the
// View locked.
conversation_name :: proc(v: ^conn.View, conv: proto.Conv_Id) -> string {
	for ch in v.channels {
		if ch.id == conv {
			return fmt.tprintf("#%s", ch.name)
		}
	}
	for &dm in v.dms {
		if dm.id == conv {
			return conn.dm_name(v, &dm)
		}
	}
	return "?"
}

@(private = "file")
LIST_TITLES := [List_Kind]string {
	.Pins      = "Pinned messages",
	.Bookmarks = "Bookmarks",
	.Search    = "Search",
}

draw_list :: proc(a: ^App, b: ^tui.Buffer) {
	v, d := a.view, &a.dialog
	w, h := min(b.w - 4, 100), min(b.h - 2, 24)
	r := tui.Rect{(b.w - w) / 2, (b.h - h) / 2, w, h}
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, LIST_TITLES[d.list])
	inner := r.w - 4
	y := r.y + 1
	if d.list == .Search {
		scope := "all conversations" if d.all else "this conversation"
		tui.put_string(b, r.x + 2, y, "Find", theme.dim)
		fx, fw := r.x + 8, r.w - 10
		tui.fill(b, {fx, y, fw, 1}, theme.reaction)
		text := tui.editor_text(&d.fields[0])
		tui.put_string(b, fx, y, tui.cut_to_width(text, fw - 1), theme.reaction, fx + fw)
		if d.field == 0 {
			a.cursor, a.cursor_shown = {fx + min(tui.string_width(text), fw - 1), y}, true
		}
		y += 1
		tui.put_string(
			b,
			r.x + 2,
			y,
			fmt.tprintf("in %s (Alt+A switches)", scope),
			theme.dim,
			r.x + r.w - 1,
		)
		y += 1
	}
	entries := list_entries(a)
	rows := r.h - (y - r.y) - 2
	d.sel = clamp(d.sel, 0, max(len(entries) - 1, 0))
	top := clamp(d.sel - rows + 1, 0, max(len(entries) - rows, 0))
	for i in top ..< min(top + rows, len(entries)) {
		e := entries[i]
		picked := i == d.sel && d.field == 1 || i == d.sel && d.list != .Search
		style := theme.selected if picked else tui.Style{}
		tui.fill(b, {r.x + 1, y, r.w - 2, 1}, style)
		line := entry_line(v, e)
		tui.put_string(b, r.x + 2, y, tui.cut_to_width(line, inner), style, r.x + r.w - 1)
		append(&a.hits, Hit{{r.x + 1, y, r.w - 2, 1}, .List_Item, u64(i), ""})
		y += 1
	}
	status: string
	switch {
	case len(entries) == 0 && list_loading(v, d.list):
		status = "loading..."
	case len(entries) == 0 && d.list == .Search && v.search.error != "":
		status = v.search.error
	case len(entries) == 0 && d.list == .Search && v.search.query == "":
		status = "Type what to look for and press Enter."
	case len(entries) == 0:
		status = "Nothing here."
	case list_more(v, d.list):
		status = fmt.tprintf("%d shown; more further down", len(entries))
	case:
		status = fmt.tprintf("%d", len(entries))
	}
	tui.put_string(b, r.x + 2, r.y + r.h - 3, status, theme.dim, r.x + r.w - 1)
	tui.put_string(
		b,
		r.x + 2,
		r.y + r.h - 2,
		"Up/Down: pick   Enter: go to it   Esc: close",
		theme.dim,
		r.x + r.w - 1,
	)
}

@(private = "file")
list_loading :: proc(v: ^conn.View, kind: List_Kind) -> bool {
	switch kind {
	case .Pins:
		return v.pins.loading
	case .Bookmarks:
		return v.bookmarks.loading || !v.bookmarks.listed
	case .Search:
		return v.search.loading
	}
	return false
}

@(private = "file")
list_more :: proc(v: ^conn.View, kind: List_Kind) -> bool {
	switch kind {
	case .Pins:
		return false
	case .Bookmarks:
		return v.bookmarks.more
	case .Search:
		return v.search.more
	}
	return false
}

// entry_line is one message as a list shows it: where, who and what.
@(private = "file")
entry_line :: proc(v: ^conn.View, e: List_Entry) -> string {
	shown, _ := shown_text(v, e.msg^)
	text, _ := strings.replace_all(shown, "\n", " ", context.temp_allocator)
	return fmt.tprintf("%s  %s: %s", conversation_name(v, e.conv), sender_name(v, e.msg^), text)
}

// list_key handles a key for the list dialog.
list_key :: proc(a: ^App, k: tui.Key_Event) {
	d := &a.dialog
	entries := list_entries(a)
	searching := d.list == .Search && d.field == 0
	switch {
	case k.key == .Escape:
		list_close(a)
		dialog_close(a)
	case d.list == .Search && k.key == .Rune && k.mods == {.Alt} && k.rune == 'a':
		d.all = !d.all
	case d.list == .Search && k.key == .Tab:
		d.field = 1 - d.field
	case k.key == .Enter && searching:
		run_search(a)
	case k.key == .Enter:
		if d.sel < len(entries) {
			e := entries[d.sel]
			goto_message(a, e.conv, e.msg.id)
			list_close(a)
			dialog_close(a)
		}
	case k.key == .Down && (!searching || len(entries) > 0):
		if searching {
			d.field = 1
		} else {
			d.sel = min(d.sel + 1, max(len(entries) - 1, 0))
			ask_more(a, len(entries))
		}
	case k.key == .Up && !searching:
		if d.sel == 0 && d.list == .Search {
			d.field = 0
		}
		d.sel = max(d.sel - 1, 0)
	case k.key == .Page_Down && !searching:
		d.sel = min(d.sel + 10, max(len(entries) - 1, 0))
		ask_more(a, len(entries))
	case k.key == .Page_Up && !searching:
		d.sel = max(d.sel - 10, 0)
	case searching:
		tui.editor_key(&d.fields[0], k)
	}
}

// ask_more asks for the next page of a list once the last entry is picked.
@(private = "file")
ask_more :: proc(a: ^App, count: int) {
	d, v := &a.dialog, a.view
	if d.sel < count - 1 || d.asked_more == count {
		return
	}
	switch d.list {
	case .Bookmarks:
		if v.bookmarks.more && !v.bookmarks.loading {
			d.asked_more = count
			push(a, conn.Bookmarks_Command{more = true})
		}
	case .Search:
		if v.search.more && !v.search.loading {
			d.asked_more = count
			push(
				a,
				conn.Search_Command {
					query = strings.clone(v.search.query),
					all = v.search.conv == 0,
					more = true,
				},
			)
		}
	case .Pins:
	}
}

// goto_message looks at a message: it switches to its conversation if need be,
// fetches the page around it if it isn't in the window, and scrolls it into view.
goto_message :: proc(a: ^App, conv: proto.Conv_Id, id: proto.Msg_Id) {
	a.jump_conv, a.jump_msg, a.jump_asked = conv, id, false
	a.jump_at = tick_now()
	a.scroll = 0
	if conv != a.view.viewing {
		push(a, conn.View_Command{conv = conv})
	}
}

// jump_step moves toward the message that goto_message was asked for. Call with
// the View locked, after the rows are laid out.
jump_step :: proc(a: ^App, g: Geometry) {
	if a.jump_msg == 0 {
		return
	}
	if tick_since(a.jump_at) > JUMP_WAIT {
		a.jump_msg = 0 // it is not coming
		return
	}
	if a.viewing != a.jump_conv {
		return
	}
	for r, i in a.layout.rows {
		if r.msg == a.jump_msg && (r.kind == .Head || r.kind == .System) {
			// In the middle of the screen.
			a.scroll = clamp(
				len(a.layout.rows) - i - g.timeline.h / 2,
				0,
				max(len(a.layout.rows) - g.timeline.h, 0),
			)
			// The keys move between the messages from there.
			a.cursor_msg = a.jump_msg
			a.focus = .Timeline
			a.jump_msg = 0
			return
		}
	}
	if !a.jump_asked {
		a.jump_asked = true
		push(a, conn.Jump_Command{id = a.jump_msg})
	}
}
