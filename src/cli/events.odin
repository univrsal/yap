package main

import "core:strings"
import "core:sync"

import "client:conn"
import "common:proto"
import "tui"

// What the keys and the mouse do. The View is locked while an event is handled
// when it has to be read.

SCROLL_STEP :: 3

app_event :: proc(a: ^App, ev: tui.Event) {
	sync.guard(&a.view.mutex)
	switch e in ev {
	case tui.Key_Event:
		key_event(a, e)
	case tui.Mouse_Event:
		mouse_event(a, e)
	case tui.Paste_Event:
		paste_event(a, e.text)
	}
}

@(private = "file")
key_event :: proc(a: ^App, k: tui.Key_Event) {
	// Leaving works wherever we are.
	if k.key == .Rune && k.mods == {.Ctrl} && (k.rune == 'c' || k.rune == 'q') {
		a.quit = true
		return
	}
	// So does going to another server: a login asked for by one is no reason to
	// be stuck there.
	if k.key == .Rune && k.mods == {.Ctrl} && (k.rune == 'n' || k.rune == 'p') && len(a.servers) > 1 {
		switch_server(a, 1 if k.rune == 'n' else -1)
		return
	}
	if k.key == .F1 {
		dialog_close(a)
		a.dialog.kind = .Help
		return
	}
	if a.dialog.kind == .None || a.dialog.kind == .Call {
		switch k.key {
		case .F5:
			set_muted(a, !a.muted)
			return
		case .F6:
			set_deafened(a, !a.deafened)
			return
		case .F7:
			toggle_voice(a)
			return
		case .F8:
			hang_up(a)
			return
		case .F9:
			open_settings(a)
			return
		case .Rune, .Enter, .Tab, .Backspace, .Escape, .Up, .Down, .Left, .Right, .Home, .End, .Page_Up, .Page_Down, .Insert, .Delete, .F1, .F2, .F3, .F4, .F10, .F11, .F12:
		}
	}
	if k.key == .Rune && k.mods == {.Ctrl} && k.rune == 'b' && a.dialog.kind == .None {
		a.list_overlay = !a.list_overlay
		return
	}
	if k.key == .Escape && a.list_overlay && a.dialog.kind == .None && !a.menu.open {
		a.list_overlay = false
		return
	}
	if k.key == .Rune && k.mods == {.Ctrl} && k.rune == 'k' && a.dialog.kind != .Palette {
		open_palette(a)
		return
	}
	if k.key == .F2 && a.dialog.kind == .None {
		a.hide_members = !a.hide_members
		a.members_asked = 0
		return
	}
	if a.dialog.kind != .None {
		dialog_key(a, k)
		return
	}
	if a.menu.open {
		menu_key(a, k)
		return
	}
	if a.focus == .Timeline || a.focus == .Thread {
		timeline_key(a, k)
		return
	}
	if completion_key(a, k) {
		return
	}
	composer_key(a, k)
}

// The messages that the keys are on: the conversation's, or the open thread's.
@(private = "file")
Pane :: struct {
	layout: ^Timeline_Layout,
	scroll: ^int,
	rect:   tui.Rect,
}

@(private = "file")
pane_of :: proc(a: ^App, thread: bool) -> Pane {
	g := geometry(a)
	if thread && a.thread != 0 {
		return {&a.thread_layout, &a.thread_scroll, {g.thread.x, g.thread.y + 1, g.thread.w, g.thread.h - 1}}
	}
	return {&a.layout, &a.scroll, g.timeline}
}

@(private = "file")
page :: proc(p: Pane) -> int {
	return max(p.rect.h - 2, 1)
}

// scroll_pane moves a pane up (rows > 0) or down.
@(private = "file")
scroll_pane :: proc(p: Pane, rows: int) {
	p.scroll^ = max(p.scroll^ + rows, 0) // (clamped to what there is by app_sync)
	if rows > 0 {
		p.scroll^ = min(p.scroll^, max(len(p.layout.rows) - p.rect.h, 0))
	}
}

@(private = "file")
scroll_by :: proc(a: ^App, rows: int) {
	scroll_pane(pane_of(a, false), rows)
}

@(private = "file")
composer_key :: proc(a: ^App, k: tui.Key_Event) {
	alt := .Alt in k.mods
	switch {
	case k.key == .Enter && k.mods == {}:
		submit(a)
		return
	case k.key == .Page_Up:
		scroll_by(a, page(pane_of(a, false)))
		return
	case k.key == .Page_Down:
		scroll_by(a, -page(pane_of(a, false)))
		return
	case k.key == .Escape:
		switch {
		case a.editing != 0: cancel_edit(a)
		case a.reply_to != 0: cancel_reply(a)
		case a.thread != 0: close_thread(a)
		case: a.scroll = 0
		}
		return
	case k.key == .Tab && k.mods == {}:
		a.focus = .Timeline
		pick_last_message(a, pane_of(a, false))
		return
	case alt && k.key == .Up:
		switch_channel(a, -1)
		return
	case alt && k.key == .Down:
		switch_channel(a, 1)
		return
	case alt && k.key == .Rune && k.rune >= '1' && k.rune <= '9':
		n := int(k.rune - '1')
		if convs := conversations_in_order(a.view); n < len(convs) {
			push(a, conn.View_Command{conv = convs[n]})
		}
		return
	case k.key == .End && k.mods == {.Ctrl}:
		a.scroll = 0
		return
	case k.key == .Up && k.mods == {} && tui.editor_text(&a.editor) == "":
		// Changing the last message is the usual reason to press up.
		if m, ok := last_own_message(a); ok {
			start_edit(a, m)
			return
		}
	}
	if tui.editor_key(&a.editor, k) {
		if a.editing == 0 && a.viewing != 0 && tui.editor_text(&a.editor) != "" && !strings.has_prefix(tui.editor_text(&a.editor), "/") {
			// Others see that we are typing.
			push(a, conn.Typing_Command{thread = {a.viewing, a.reply_to}})
		}
	}
}

// pick_last_message puts the message cursor on the newest message of a pane.
@(private = "file")
pick_last_message :: proc(a: ^App, p: Pane) {
	#reverse for r in p.layout.rows {
		if r.msg != 0 {
			a.cursor_msg = r.msg
			return
		}
	}
	a.cursor_msg = 0
}

@(private = "file")
timeline_key :: proc(a: ^App, k: tui.Key_Event) {
	in_thread := a.focus == .Thread
	p := pane_of(a, in_thread)
	switch {
	case k.key == .Tab && !in_thread && a.thread != 0:
		// From the messages to the thread, then back to the message box.
		a.focus = .Thread
		pick_last_message(a, pane_of(a, true))
	case k.key == .Tab, k.key == .Escape:
		a.focus = .Composer
		a.cursor_msg = 0
	case k.key == .Up:
		move_cursor(a, p, -1)
	case k.key == .Down:
		move_cursor(a, p, 1)
	case k.key == .Page_Up:
		scroll_pane(p, page(p))
	case k.key == .Page_Down:
		scroll_pane(p, -page(p))
	case k.key == .Enter:
		if m, ok := find_message(a, a.cursor_msg); ok {
			menu_open(a, m^, p.rect.x + 10, p.rect.y + p.rect.h / 2)
		}
	case k.key == .Rune && k.mods == {}:
		// The most used actions have their own keys.
		m, ok := find_message(a, a.cursor_msg)
		if !ok {
			return
		}
		switch k.rune {
		case 'r': start_reply(a, m^)
		case 'e':
			if can_edit(a.view, m^) {
				start_edit(a, m^)
			}
		case 'd':
			if can_delete(a.view, m^) {
				a.dialog.kind, a.dialog.msg = .Confirm_Delete, m.id
			}
		case 'y': copy_text(a, m.text)
		case 't':
			if .Has_Thread in m.flags || m.thread_root != 0 {
				open_thread(a, thread_root_of(m^))
				a.focus = .Composer
			}
		case 'a':
			if can_react(a.view) {
				open_picker(a, m.id)
			}
		}
	}
}

// move_cursor moves the message cursor to the message before or after it in a
// pane, scrolling to keep it in view.
@(private = "file")
move_cursor :: proc(a: ^App, p: Pane, dir: int) {
	rows := p.layout.rows
	// The rows of the message the cursor is on.
	idx := -1
	for r, i in rows {
		if r.msg == a.cursor_msg && a.cursor_msg != 0 {
			idx = i
			break
		}
	}
	i := idx + dir if idx >= 0 else len(rows) - 1
	for i >= 0 && i < len(rows) && (rows[i].msg == 0 || rows[i].msg == a.cursor_msg) {
		i += dir
	}
	if i < 0 || i >= len(rows) {
		return
	}
	a.cursor_msg = rows[i].msg
	// Keep the row in view.
	h := p.rect.h
	end := len(rows) - p.scroll^
	if i >= end {
		p.scroll^ = len(rows) - i - 1
	} else if i < end - h {
		p.scroll^ = len(rows) - i - h
	}
	p.scroll^ = max(p.scroll^, 0)
}

@(private = "file")
menu_key :: proc(a: ^App, k: tui.Key_Event) {
	m := &a.menu
	switch {
	case k.key == .Escape:
		menu_close(a)
	case k.key == .Up:
		m.sel = (m.sel - 1 + len(m.items)) % len(m.items)
	case k.key == .Down, k.key == .Tab:
		m.sel = (m.sel + 1) % len(m.items)
	case k.key == .Enter:
		menu_choose(a, m.sel)
	case k.key == .Rune && k.mods == {}:
		// The first letter of an item.
		for it, i in m.items {
			if strings.to_lower(it.label[:1], context.temp_allocator) == strings.to_lower(string([]u8{u8(k.rune)}), context.temp_allocator) {
				menu_choose(a, i)
				return
			}
		}
	}
}

@(private = "file")
menu_choose :: proc(a: ^App, i: int) {
	if i < 0 || i >= len(a.menu.items) {
		return
	}
	action, id, arg := a.menu.items[i].action, a.menu.msg, a.menu.items[i].arg
	menu_close(a)
	m, ok := find_message(a, id)
	if !ok {
		return
	}
	switch action {
	case .Reply: start_reply(a, m^)
	case .React: open_picker(a, id)
	case .Save:
		push(a, conn.Attach_Save_Command{msg = id, index = arg})
		say(a, "Saving...")
	case .Thread: open_thread(a, thread_root_of(m^))
	case .Bookmark: push(a, conn.Bookmark_Command{id = id, on = !a.view.bookmarks.ids[id]})
	case .Pin: push(a, conn.Pin_Command{id = id, on = .Pinned not_in m.flags})
	case .Edit: start_edit(a, m^)
	case .Copy: copy_text(a, m.text)
	case .Delete: a.dialog.kind, a.dialog.msg = .Confirm_Delete, id
	}
}

// switch_channel looks at the channel before or after the one shown.
@(private = "file")
switch_channel :: proc(a: ^App, dir: int) {
	convs := conversations_in_order(a.view)
	if len(convs) == 0 {
		return
	}
	at := -1
	for id, i in convs {
		if id == a.view.viewing {
			at = i
		}
	}
	next := (at + dir + len(convs)) % len(convs) if at >= 0 else 0
	push(a, conn.View_Command{conv = convs[next]})
}

@(private = "file")
mouse_event :: proc(a: ^App, m: tui.Mouse_Event) {
	g := geometry(a)
	if m.button == .Left && selection_mouse(a, m, g) {
		return
	}
	if a.drag == .Border {
		switch m.kind {
		case .Drag, .Move, .Press:
			a.channel_w = clamp(m.x, CHANNEL_W_MIN, max(a.size.x / 2, CHANNEL_W_MIN))
		case .Release, .Wheel_Up, .Wheel_Down:
			a.drag = .None
		}
		return
	}
	// Wheels turn whatever is under them.
	if m.kind == .Wheel_Up || m.kind == .Wheel_Down {
		dir := 1 if m.kind == .Wheel_Up else -1
		switch {
		case a.dialog.kind != .None:
		case tui.rect_contains(g.channels, m.x, m.y):
			a.chan_scroll = max(a.chan_scroll - dir * SCROLL_STEP, 0)
		case tui.rect_contains(g.thread, m.x, m.y):
			a.thread_scroll = max(a.thread_scroll + dir * SCROLL_STEP, 0)
		case tui.rect_contains(g.members, m.x, m.y):
			a.members_scroll = max(a.members_scroll - dir * SCROLL_STEP, 0)
		case:
			scroll_by(a, dir * SCROLL_STEP)
		}
		return
	}
	if m.kind != .Press || m.button != .Left && m.button != .Right {
		return
	}
	hit, found := hit_at(a, m.x, m.y)
	if a.menu.open {
		// Choosing an item, or anywhere else to close the menu.
		if found && hit.kind == .Menu_Item {
			menu_choose(a, int(hit.id))
		} else {
			menu_close(a)
		}
		return
	}
	if a.dialog.kind == .List {
		if found && hit.kind == .List_Item {
			a.dialog.sel = int(hit.id)
			list_key(a, tui.Key_Event{key = .Enter})
		} else if !found || hit.kind != .Dialog {
			list_close(a)
			dialog_close(a)
		}
		return
	}
	if a.dialog.kind == .Picker {
		if found && hit.kind == .Emoji {
			picker_choose(a, int(hit.id))
		} else if !found || hit.kind != .Dialog {
			dialog_close(a)
		}
		return
	}
	if a.dialog.kind == .Palette {
		if found && hit.kind == .Palette_Item {
			palette_choose(a, int(hit.id))
		} else if !found || hit.kind != .Dialog {
			dialog_close(a)
		}
		return
	}
	if a.dialog.kind == .Form {
		if found && hit.kind == .Form_Field {
			a.dialog.form.sel = int(hit.id)
			fl := &a.dialog.form.fields[hit.id]
			if fl.kind != .Text {
				form_key(a, tui.Key_Event{key = .Right})
			}
		} else if !found || hit.kind != .Dialog {
			dialog_close(a)
		}
		return
	}
	if a.dialog.kind == .Settings {
		if found && hit.kind == .Setting_Row {
			a.dialog.sel = int(hit.id)
			setting_change(a, Setting(hit.id), 1)
		} else if !found || hit.kind != .Dialog {
			dialog_close(a)
		}
		return
	}
	if a.dialog.kind != .None || !found {
		return
	}
	switch hit.kind {
	case .Channel:
		push(a, conn.View_Command{conv = proto_conv(hit.id)})
		a.list_overlay = false
	case .Message:
		// A click opens the menu, but a drag selects text: it is told apart when
		// the button comes up.
		if m.button == .Left {
			a.press = Press{m.x, m.y, hit.id}
		} else if msg, ok := find_message(a, proto_msg(hit.id)); ok {
			menu_open(a, msg^, m.x, m.y)
		}
	case .Thread:
		open_thread(a, proto_msg(hit.id))
	case .Close_Thread:
		close_thread(a)
	case .Server:
		app_switch(a, int(hit.id))
	case .Border:
		a.drag = .Border
	case .Reaction:
		if can_react(a.view) {
			react(a, proto_msg(hit.id), hit.text)
		}
	case .Completion:
		completion_choose(a, int(hit.id))
	case .Palette_Item, .Form_Field:
	case .Overlay_Close:
		a.list_overlay = false
	case .Setting_Row:
		a.dialog.sel = int(hit.id)
		setting_change(a, Setting(hit.id), 1)
	case .Voice_Join:
		toggle_voice_of(a, proto_conv(hit.id))
	case .Emoji, .List_Item:
	case .Member:
		// Writing to someone starts with their DM.
		if hit.id != u64(a.view.me) {
			if acc, ok := a.view.accounts[proto.Account_Id(hit.id)]; ok {
				push(a, conn.DM_Command{name = strings.clone(acc.username)})
			}
		}
	case .Composer:
		a.focus = .Composer
		a.cursor_msg = 0
	case .Menu_Item, .Dialog:
	}
}

@(private = "file")
paste_event :: proc(a: ^App, text: string) {
	if a.dialog.kind != .None {
		dialog_paste(a, text)
		return
	}
	// Line ends of any kind become newlines, and other control characters go.
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	prev_cr := false
	for r in text {
		switch {
		case r == '\r':
			strings.write_byte(&b, '\n')
			prev_cr = true
			continue
		case r == '\n':
			if !prev_cr {
				strings.write_byte(&b, '\n')
			}
		case r == '\t':
			strings.write_string(&b, "    ")
		case r < 0x20 || r == 0x7f:
		case:
			strings.write_rune(&b, r)
		}
		prev_cr = false
	}
	tui.editor_insert(&a.editor, strings.to_string(b))
	a.focus = .Composer
}

@(private = "file")
proto_conv :: proc(id: u64) -> proto.Conv_Id {
	return proto.Conv_Id(id)
}

@(private = "file")
proto_msg :: proc(id: u64) -> proto.Msg_Id {
	return proto.Msg_Id(id)
}

// selection_mouse handles a drag that selects text and the release that ends a
// click or a drag. It says whether the event was used up.
@(private = "file")
selection_mouse :: proc(a: ^App, m: tui.Mouse_Event, g: Geometry) -> bool {
	switch m.kind {
	case .Drag:
		if p, ok := a.press.?; ok && (m.x != p.x || m.y != p.y) {
			if pane, in_pane := sel_pane(g, p.x, p.y); in_pane {
				a.sel = {true, pane, {p.x, p.y}, {m.x, m.y}}
			}
			a.press = nil
		}
		if a.sel.active {
			a.sel.head = {
				clamp(m.x, a.sel.pane.x, a.sel.pane.x + a.sel.pane.w - 1),
				clamp(m.y, a.sel.pane.y, a.sel.pane.y + a.sel.pane.h - 1),
			}
			return true
		}
	case .Release:
		if a.sel.active {
			if a.frame != nil {
				if text := sel_text(a.sel, a.frame); text != "" {
					copy_text(a, text)
				}
			}
			a.sel.active = false
			return true
		}
		if p, ok := a.press.?; ok {
			a.press = nil
			if p.x == m.x && p.y == m.y {
				if msg, found := find_message(a, proto_msg(p.msg)); found {
					menu_open(a, msg^, m.x, m.y)
				}
			}
			return true
		}
	case .Press, .Move, .Wheel_Up, .Wheel_Down:
	}
	return false
}

// toggle_voice_of joins the voice room of a channel, or leaves it if we are in it.
@(private = "file")
toggle_voice_of :: proc(a: ^App, conv: proto.Conv_Id) {
	if a.view.my_room == conv {
		leave_voice(a)
		return
	}
	for ch in a.view.channels {
		if ch.id == conv && has_voice(ch) {
			join_voice(a, ch)
			return
		}
	}
}
