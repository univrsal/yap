package main

import "core:fmt"
import "core:strings"

import "client:conn"
import "common:."
import "common:proto"
import "tui"

// Windows over the screen: a dialog, which takes the keys until it is closed, and
// the menu of what can be done to a message.

Dialog_Kind :: enum {
	None,
	Login, // the server doesn't know this device yet
	Key_Change, // the server's key is not the one saved for it
	Confirm_Delete,
	Help,
	Output, // text an answer of a command
	Picker, // an emoji to react to a message with
	List, // pinned messages, bookmarks or a search
}

Dialog :: struct {
	kind:   Dialog_Kind,
	fields: [2]tui.Editor, // the login's user name and password
	field:  int,
	msg:    proto.Msg_Id, // what a Confirm_Delete is about
	text:   string, // what an Output shows (owned)
	sel:    int, // the emoji picked in a Picker, the entry in a List
	list:   List_Kind,
	all:    bool, // a search of all conversations
	asked_more: int, // how many entries there were when the next page was asked for
}

dialog_close :: proc(a: ^App) {
	delete(a.dialog.text)
	for &f in a.dialog.fields {
		tui.editor_destroy(&f)
	}
	a.dialog = {}
}

// dialog_update opens and closes the dialogs that follow from the connection:
// a changed server key and a login are asked for as long as they are needed.
// Call with the View locked.
dialog_update :: proc(a: ^App) {
	v := a.view
	want := a.dialog.kind
	switch {
	case a.dialog.kind == .Help || a.dialog.kind == .Confirm_Delete || a.dialog.kind == .Output || a.dialog.kind == .Picker || a.dialog.kind == .List:
		return
	case v.key_change.changed:
		want = .Key_Change
	case v.login.state == .Needed && v.status == .Connected:
		want = .Login
	case:
		want = .None
	}
	if want != a.dialog.kind {
		dialog_close(a)
		a.dialog.kind = want
	}
}

Menu_Action :: enum {
	Reply,
	Save, // a file of the message; Menu_Item.arg is which
	Pin,
	Bookmark,
	Thread,
	React,
	Edit,
	Delete,
	Copy,
}

Menu_Item :: struct {
	label:  string,
	action: Menu_Action,
	arg:    int,
}

Menu :: struct {
	open:  bool,
	msg:   proto.Msg_Id,
	items: [dynamic]Menu_Item,
	at:    [2]int, // where it was asked for
	rect:  tui.Rect, // where it is drawn, which is moved in to fit
	sel:   int,
}

menu_close :: proc(a: ^App) {
	a.menu.open = false
	clear(&a.menu.items)
	delete(a.menu.items)
	a.menu.items = nil
}

// menu_open lists what can be done to a message. Call with the View locked.
menu_open :: proc(a: ^App, m: conn.View_Message, x, y: int) {
	menu_close(a)
	v := a.view
	items := &a.menu.items
	if can_write(v) {
		append(items, Menu_Item{"Reply", .Reply, 0})
	}
	if .Has_Thread in m.flags || m.thread_root != 0 {
		append(items, Menu_Item{"Open thread", .Thread, 0})
	}
	if can_react(v) {
		append(items, Menu_Item{"Add reaction", .React, 0})
	}
	if can_edit(v, m) {
		append(items, Menu_Item{"Edit", .Edit, 0})
	}
	append(items, Menu_Item{"Copy text", .Copy, 0})
	for f, i in m.files {
		label := "Save file" if len(m.files) == 1 else fmt.tprintf("Save %s", f.name)
		append(items, Menu_Item{label, .Save, i})
	}
	if len(m.files) == 0 && m.kind == .File {
		append(items, Menu_Item{"Save file", .Save, 0})
	}
	append(items, Menu_Item{"Remove bookmark" if v.bookmarks.ids[m.id] else "Bookmark", .Bookmark, 0})
	if .Pin_Messages in v.permissions && .Deleted not_in m.flags {
		append(items, Menu_Item{"Unpin" if .Pinned in m.flags else "Pin", .Pin, 0})
	}
	if can_delete(v, m) {
		append(items, Menu_Item{"Delete", .Delete, 0})
	}
	a.menu.open, a.menu.msg, a.menu.at, a.menu.sel = true, m.id, {x, y}, 0
	a.cursor_msg = m.id
}

draw_overlays :: proc(a: ^App, b: ^tui.Buffer) {
	if a.dialog.kind != .None {
		draw_dialog(a, b)
	} else if a.menu.open {
		draw_menu(a, b)
	}
}

@(private = "file")
draw_menu :: proc(a: ^App, b: ^tui.Buffer) {
	m := &a.menu
	w := 0
	for it in m.items {
		w = max(w, tui.string_width(it.label))
	}
	w += 4
	h := len(m.items)
	// Where it fits: by the click, moved in if it would stick out.
	x := clamp(m.at.x, 0, max(b.w - w, 0))
	y := clamp(m.at.y, 0, max(b.h - h, 0))
	m.rect = {x, y, w, h}
	append(&a.hits, Hit{{0, 0, b.w, b.h}, .Dialog, 0, ""}) // a click elsewhere closes it
	for it, i in m.items {
		style := theme.selected if i == m.sel else theme.bar
		tui.fill(b, {x, y + i, w, 1}, style)
		tui.put_string(b, x + 2, y + i, it.label, style, x + w)
		append(&a.hits, Hit{{x, y + i, w, 1}, .Menu_Item, u64(i), ""})
	}
}

draw_box :: proc(b: ^tui.Buffer, r: tui.Rect, title: string) {
	tui.fill(b, r, {})
	s := theme.border
	for x in r.x + 1 ..< r.x + r.w - 1 {
		tui.set_cell(b, x, r.y, '─', 1, s)
		tui.set_cell(b, x, r.y + r.h - 1, '─', 1, s)
	}
	for y in r.y + 1 ..< r.y + r.h - 1 {
		tui.set_cell(b, r.x, y, '│', 1, s)
		tui.set_cell(b, r.x + r.w - 1, y, '│', 1, s)
	}
	tui.set_cell(b, r.x, r.y, '┌', 1, s)
	tui.set_cell(b, r.x + r.w - 1, r.y, '┐', 1, s)
	tui.set_cell(b, r.x, r.y + r.h - 1, '└', 1, s)
	tui.set_cell(b, r.x + r.w - 1, r.y + r.h - 1, '┘', 1, s)
	tui.put_string(b, r.x + 2, r.y, fmt.tprintf(" %s ", title), {attrs = {.Bold}}, r.x + r.w - 1)
}

// dialog_rect is where a dialog of this size goes: in the middle.
@(private = "file")
dialog_rect :: proc(b: ^tui.Buffer, want_w, want_h: int) -> tui.Rect {
	w, h := min(want_w, b.w), min(want_h, b.h)
	return {(b.w - w) / 2, (b.h - h) / 2, w, h}
}

@(private = "file")
draw_dialog :: proc(a: ^App, b: ^tui.Buffer) {
	v := a.view
	d := &a.dialog
	switch d.kind {
	case .None:
	case .Login:
		r := dialog_rect(b, 46, 9)
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "Log in")
		name := v.server_name if v.server_name != "" else v.server
		tui.put_string(b, r.x + 2, r.y + 1, fmt.tprintf("%s doesn't know this device.", name), theme.dim, r.x + r.w - 1)
		labels := [2]string{"User name", "Password"}
		for i in 0 ..< 2 {
			y := r.y + 3 + i
			tui.put_string(b, r.x + 2, y, labels[i], theme.dim)
			fx, fw := r.x + 14, r.w - 16
			tui.fill(b, {fx, y, fw, 1}, theme.reaction)
			text := tui.editor_text(&d.fields[i])
			shown := strings.repeat("•", tui.string_width(text), context.temp_allocator) if i == 1 else text
			tui.put_string(b, fx, y, tui.cut_to_width(shown, fw - 1), theme.reaction, fx + fw)
			if i == d.field {
				cx := min(tui.string_width(shown), fw - 1)
				a.cursor, a.cursor_shown = {fx + cx, y}, true
			}
		}
		if v.login.error != "" {
			tui.put_string(b, r.x + 2, r.y + 6, v.login.error, theme.error, r.x + r.w - 1)
		}
		tui.put_string(b, r.x + 2, r.y + 7, "Tab: next field   Enter: log in   Ctrl+C: quit", theme.dim, r.x + r.w - 1)
	case .Key_Change:
		r := dialog_rect(b, 72, 14)
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "The server's key has changed")
		kc := &v.key_change
		tui.put_string(b, r.x + 2, r.y + 1, kc.server, {attrs = {.Bold}}, r.x + r.w - 1)
		tui.put_string(b, r.x + 2, r.y + 3, "saved", theme.dim)
		tui.put_string(b, r.x + 2, r.y + 4, "new", theme.dim)
		tui.put_string(b, r.x + 9, r.y + 3, common.key_hex(kc.saved)[:32], {}, r.x + r.w - 1)
		tui.put_string(b, r.x + 9, r.y + 4, common.key_hex(kc.received)[:32], theme.error, r.x + r.w - 1)
		text := "A key normally stays the same. It changes when the server is set up again, but it is also what you would see if someone were pretending to be the server. Only trust the new one if the person running it says it changed: the server logs its key when it starts."
		lines := make([dynamic]tui.Line, context.temp_allocator)
		tui.wrap(text, r.w - 4, &lines)
		for l, i in lines {
			tui.put_string(b, r.x + 2, r.y + 6 + i, text[l.start:l.end], {}, r.x + r.w - 1)
		}
		tui.put_string(b, r.x + 2, r.y + r.h - 2, "T: trust the new key and connect   Q: quit", {attrs = {.Bold}}, r.x + r.w - 1)
	case .Confirm_Delete:
		r := dialog_rect(b, 40, 5)
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "Delete message")
		tui.put_string(b, r.x + 2, r.y + 2, "Delete this message for everyone?", {}, r.x + r.w - 1)
		tui.put_string(b, r.x + 2, r.y + 3, "Y: delete   N: keep it", theme.dim, r.x + r.w - 1)
	case .List:
		draw_list(a, b)
	case .Picker:
		rows := (len(PICKER_EMOJI) + PICKER_COLUMNS - 1) / PICKER_COLUMNS
		r := dialog_rect(b, PICKER_COLUMNS * PICKER_CELL + 3, rows + 4)
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "React with")
		for e, i in PICKER_EMOJI {
			cell := tui.Rect{r.x + 2 + (i % PICKER_COLUMNS) * PICKER_CELL, r.y + 2 + i / PICKER_COLUMNS, PICKER_CELL, 1}
			style := theme.selected if i == d.sel else tui.Style{}
			tui.fill(b, cell, style)
			tui.put_string(b, cell.x + 1, cell.y, e, style)
			append(&a.hits, Hit{cell, .Emoji, u64(i), ""})
		}
		tui.put_string(b, r.x + 2, r.y + r.h - 2, "Enter: choose   /react <id> :name: for others", theme.dim, r.x + r.w - 1)
	case .Output:
		r := dialog_rect(b, min(b.w - 4, 90), min(b.h - 2, 20))
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "Output (any key closes)")
		lines := make([dynamic]tui.Line, context.temp_allocator)
		tui.wrap(d.text, r.w - 4, &lines)
		for l, i in lines {
			if i >= r.h - 3 {
				break
			}
			tui.put_string(b, r.x + 2, r.y + 2 + i, d.text[l.start:l.end], {}, r.x + r.w - 1)
		}
	case .Help:
		lines := HELP_LINES
		r := dialog_rect(b, 64, len(lines) + 4)
		append(&a.hits, Hit{r, .Dialog, 0, ""})
		draw_box(b, r, "Keys")
		for l, i in lines {
			tui.put_string(b, r.x + 2, r.y + 2 + i, l, {}, r.x + r.w - 1)
		}
	}
}

HELP_LINES :: [?]string {
	"Enter            send the message",
	"Alt+Enter        a new line in the message",
	"Up (empty box)   edit your last message",
	"Esc              cancel a reply or edit; back to the newest",
	"PgUp / PgDn      scroll the messages",
	"Alt+Up / Down    previous / next channel (Alt+1..9: by number)",
	"Tab              pick a message with the keys (Up/Down, then",
	"                 Enter for its menu, Tab or Esc to leave)",
	"mouse            click a channel or a message; wheel scrolls;",
	"                 drag the border to resize the list",
	"F2              show or hide the member list (on wide screens)",
	"/pins /bookmarks /search [all] <words>   lists of messages",
	"/join <channel>  look at a channel      /help   this list",
	"/quit            leave                  Ctrl+C  leave",
}

// dialog_key handles a key for the dialog that is open.
dialog_key :: proc(a: ^App, k: tui.Key_Event) {
	d := &a.dialog
	v := a.view
	switch d.kind {
	case .None:
	case .Login:
		switch {
		case k.key == .Tab || k.key == .Down || k.key == .Up:
			d.field = 1 - d.field
		case k.key == .Enter:
			if d.field == 0 {
				d.field = 1
				return
			}
			user := strings.trim_space(tui.editor_text(&d.fields[0]))
			if user == "" {
				d.field = 0
				return
			}
			push(
				a,
				conn.Login_Command {
					username = strings.clone(user),
					password = strings.clone(tui.editor_text(&d.fields[1])),
					device = strings.clone(a.device),
				},
			)
			tui.editor_clear(&d.fields[1])
		case:
			tui.editor_key(&d.fields[d.field], k)
		}
	case .Key_Change:
		if k.key == .Rune && k.mods == {} {
			switch k.rune {
			case 't', 'T':
				kc := v.key_change
				if conn.replace_server_key(a.known_servers, kc.server, kc.received) {
					request_reconnect(a)
					dialog_close(a)
				} else {
					say(a, "Could not save the new key.", true)
				}
			case 'q', 'Q':
				a.quit = true
			}
		}
	case .Confirm_Delete:
		switch {
		case k.key == .Rune && (k.rune == 'y' || k.rune == 'Y'), k.key == .Enter:
			push(a, conn.Delete_Command{id = d.msg})
			dialog_close(a)
		case k.key == .Escape, k.key == .Rune && (k.rune == 'n' || k.rune == 'N'):
			dialog_close(a)
		}
	case .Help, .Output:
		dialog_close(a)
	case .List:
		list_key(a, k)
	case .Picker:
		switch k.key {
		case .Left: d.sel = max(d.sel - 1, 0)
		case .Right: d.sel = min(d.sel + 1, len(PICKER_EMOJI) - 1)
		case .Up: d.sel = max(d.sel - PICKER_COLUMNS, 0)
		case .Down: d.sel = min(d.sel + PICKER_COLUMNS, len(PICKER_EMOJI) - 1)
		case .Enter: picker_choose(a, d.sel)
		case .Escape: dialog_close(a)
		case .Rune, .Tab, .Backspace, .Home, .End, .Page_Up, .Page_Down, .Insert, .Delete, .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
		}
	}
}

PICKER_EMOJI := [?]string {
	"👍", "👎", "❤️", "😂", "😮", "😢", "🎉", "🙏",
	"👀", "🔥", "✅", "❌", "💯", "🤔", "👏", "😀",
	"😍", "😎", "🙌", "💪", "🚀", "⭐", "😅", "🤝",
}
PICKER_COLUMNS :: 8
PICKER_CELL :: 4

open_picker :: proc(a: ^App, msg: proto.Msg_Id) {
	dialog_close(a)
	a.dialog.kind, a.dialog.msg = .Picker, msg
}

// picker_choose reacts to the message with the emoji at i, or takes the reaction
// back if it is ours already. Call with the View locked.
picker_choose :: proc(a: ^App, i: int) {
	if i < 0 || i >= len(PICKER_EMOJI) {
		return
	}
	id := a.dialog.msg
	react(a, id, PICKER_EMOJI[i])
	dialog_close(a)
}

// react toggles our reaction to a message. Call with the View locked.
react :: proc(a: ^App, id: proto.Msg_Id, emoji: string) {
	on := true
	if m, ok := find_message(a, id); ok {
		for r in m.reactions {
			if r.emoji == emoji && r.me {
				on = false
			}
		}
	}
	push(a, conn.React_Command{id = id, emoji = strings.clone(emoji), on = on})
}

// dialog_paste puts pasted text in the field of a dialog that has one.
dialog_paste :: proc(a: ^App, text: string) {
	if a.dialog.kind == .List && a.dialog.list == .Search {
		line, _, _ := strings.partition(text, "\n")
		tui.editor_insert(&a.dialog.fields[0], strings.trim_right_space(line))
		a.dialog.field = 0
	}
	if a.dialog.kind == .Login {
		line, _, _ := strings.partition(text, "\n")
		tui.editor_insert(&a.dialog.fields[a.dialog.field], strings.trim_right_space(line))
	}
}

