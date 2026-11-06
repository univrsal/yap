package main

import "core:slice"
import "core:strings"

import "client:conn"
import "client:richtext"
import "common:proto"
import "tui"

// Completion in the message box: while the word at the cursor starts with `@`
// the accounts (and roles) it could be are listed over the box, and while the
// text starts with `/` the commands. Up and Down move, Tab or Enter choose,
// Escape closes it until the word changes, and a click chooses.
//
// This is the terminal's own matching; the window client's is in
// ui_completion.odin (which is tied to its widgets), so changes to what
// matches go in both. Emoji shortcodes (:name:) are not completed yet.

COMPLETION_MAX :: 6

Completion_Item :: struct {
	insert: string, // what the word becomes (in the temp allocator)
	label:  string,
}

Completion :: struct {
	active:    bool,
	items:     [dynamic]Completion_Item,
	selected:  int,
	start:     int, // where the word starts and where it ends (the cursor), in the text
	end:       int,
	dismissed: string, // the word that was closed with Escape (owned)
}

completion_destroy :: proc(c: ^Completion) {
	delete(c.items)
	delete(c.dismissed)
	c^ = {}
}

// What can be typed as a command, without the slash. The headless client's
// commands are many; these are the ones to find by completing.
COMMAND_NAMES := [?]string {
	"accept", "activity", "answer", "ban", "bans", "bookmark", "bookmarks", "buddies", "buddy",
	"call", "cancel", "channels", "create", "decline", "delete", "dm", "edit", "file", "forward",
	"group", "hangup", "help", "invite", "join", "jump", "leave", "members", "mute", "notify",
	"older", "newer", "pin", "pins", "quit", "react", "reply", "roles", "save", "search", "seen",
	"status", "thread", "unattach", "unbookmark", "unmute", "unpin", "unreact", "attach", "deafen",
	"undeafen", "browse", "subscribe", "unsubscribe", "topic", "rename", "kick", "devices", "logout",
}

@(private = "file")
word_byte :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '-':
		return true
	}
	return false
}

// completion_update works out the list from the text and the cursor. Call with
// the View locked.
completion_update :: proc(a: ^App) {
	c := &a.completion
	clear(&c.items)
	c.active = false
	if a.dialog.kind != .None || a.focus != .Composer {
		return
	}
	text := tui.editor_text(&a.editor)
	cursor := a.editor.cursor
	if strings.has_prefix(text, "/") && !strings.has_prefix(text, "//") && !strings.contains_any(text[:cursor], " \t\n") {
		command_items(a, strings.to_lower(text[1:cursor], context.temp_allocator))
		c.start, c.end = 0, cursor
	} else {
		start := cursor
		for start > 0 && word_byte(text[start - 1]) {
			start -= 1
		}
		if start == 0 || text[start - 1] != '@' || start > 1 && !strings.is_space(rune(text[start - 2])) {
			// A role's name may have spaces; only the usernames are completed past one.
			mention_roles_with_spaces(a, text, cursor)
			if len(c.items) == 0 {
				delete(c.dismissed)
				c.dismissed = ""
				return
			}
		} else {
			c.start, c.end = start - 1, cursor
			mention_items(a, strings.to_lower(text[start:cursor], context.temp_allocator))
		}
	}
	if len(c.items) == 0 {
		return
	}
	// What is typed already is the only thing it could become: nothing to offer,
	// and Enter sends the message.
	if len(c.items) == 1 && strings.trim_right_space(c.items[0].insert) == text[c.start:c.end] {
		clear(&c.items)
		return
	}
	if text[c.start:c.end] == c.dismissed {
		clear(&c.items)
		return
	}
	c.active = true
	c.selected = clamp(c.selected, 0, len(c.items) - 1)
}

@(private = "file")
mention_items :: proc(a: ^App, prefix: string) {
	v, c := a.view, &a.completion
	Candidate :: struct {
		insert, label, key: string,
		here:               bool,
	}
	found := make([dynamic]Candidate, context.temp_allocator)
	for id, acc in v.accounts {
		if id == v.me || acc.flags & {.Disabled, .Deleted} != {} {
			continue
		}
		if strings.has_prefix(acc.username, prefix) ||
		   strings.has_prefix(strings.to_lower(acc.display, context.temp_allocator), prefix) {
			here := false
			for _, u in v.users {
				here ||= u.account == id
			}
			append(
				&found,
				Candidate {
					insert = strings.concatenate({"@", acc.username, " "}, context.temp_allocator),
					label = strings.concatenate({"@", acc.username, "   ", acc.display}, context.temp_allocator),
					key = acc.username,
					here = here,
				},
			)
		}
	}
	// Those who are here first, then by username.
	slice.sort_by(found[:], proc(a, b: Candidate) -> bool {
		if a.here != b.here {
			return a.here
		}
		return a.key < b.key
	})
	for f, i in found {
		if i >= COMPLETION_MAX {
			break
		}
		append(&c.items, Completion_Item{f.insert, f.label})
	}
	for r in v.roles {
		if richtext.role_mentionable(r) && strings.has_prefix(strings.to_lower(r.name, context.temp_allocator), prefix) {
			append(
				&c.items,
				Completion_Item {
					strings.concatenate({"@", r.name, " "}, context.temp_allocator),
					strings.concatenate({"@", r.name, "   role"}, context.temp_allocator),
				},
			)
		}
	}
	if .Mention_Everyone in v.permissions {
		if strings.has_prefix(proto.MENTION_EVERYONE, prefix) {
			append(&c.items, Completion_Item{"@" + proto.MENTION_EVERYONE + " ", "@" + proto.MENTION_EVERYONE + "   everyone"})
		}
		if strings.has_prefix(proto.MENTION_HERE, prefix) {
			append(&c.items, Completion_Item{"@" + proto.MENTION_HERE + " ", "@" + proto.MENTION_HERE + "   everyone who is online"})
		}
	}
}

// mention_roles_with_spaces lists the roles whose names (which may have spaces)
// the text after an earlier `@` is the start of.
@(private = "file")
mention_roles_with_spaces :: proc(a: ^App, text: string, cursor: int) {
	v, c := a.view, &a.completion
	at := strings.last_index_byte(text[:cursor], '@')
	if at < 0 || at > 0 && !strings.is_space(rune(text[at - 1])) {
		return
	}
	typed := strings.to_lower(text[at + 1:cursor], context.temp_allocator)
	if !strings.contains(typed, " ") {
		return
	}
	for r in v.roles {
		if richtext.role_mentionable(r) && strings.has_prefix(strings.to_lower(r.name, context.temp_allocator), typed) {
			append(
				&c.items,
				Completion_Item {
					strings.concatenate({"@", r.name, " "}, context.temp_allocator),
					strings.concatenate({"@", r.name, "   role"}, context.temp_allocator),
				},
			)
		}
	}
	c.start, c.end = at, cursor
}

@(private = "file")
command_items :: proc(a: ^App, prefix: string) {
	c := &a.completion
	for name in COMMAND_NAMES {
		if strings.has_prefix(name, prefix) {
			append(
				&c.items,
				Completion_Item {
					strings.concatenate({"/", name, " "}, context.temp_allocator),
					strings.concatenate({"/", name}, context.temp_allocator),
				},
			)
		}
	}
	// The bots' commands that could be here.
	only: []proto.Account_Id
	limited := false
	if dm := viewed_dm(a.view); dm != nil {
		limited = true
		only = conn.group_members(dm)
		if len(only) == 0 {
			only = {dm.with}
		}
	}
	for e in conn.bot_commands_scope(a.view.bot_commands[:], only, limited) {
		if strings.has_prefix(strings.to_lower(e.name, context.temp_allocator), prefix) {
			append(
				&c.items,
				Completion_Item {
					strings.concatenate({"/", e.name, " "}, context.temp_allocator),
					strings.concatenate({"/", e.name, "   ", e.description, " (", e.bot, ")"}, context.temp_allocator),
				},
			)
		}
	}
	slice.sort_by(c.items[:], proc(a, b: Completion_Item) -> bool {
		return a.insert < b.insert
	})
	// The same name from several bots stays, told apart by the bot in its label.
	if len(c.items) > 2 * COMPLETION_MAX {
		resize(&c.items, 2 * COMPLETION_MAX)
	}
}

// completion_key handles the keys of an open list; it says whether it took the key.
completion_key :: proc(a: ^App, k: tui.Key_Event) -> bool {
	c := &a.completion
	if !c.active || k.mods != {} {
		return false
	}
	switch k.key {
	case .Up:
		c.selected = (c.selected - 1 + len(c.items)) % len(c.items)
	case .Down:
		c.selected = (c.selected + 1) % len(c.items)
	case .Tab, .Enter:
		completion_choose(a, c.selected)
	case .Escape:
		delete(c.dismissed)
		c.dismissed = strings.clone(tui.editor_text(&a.editor)[c.start:c.end])
		c.active = false
		clear(&c.items)
	case .Rune, .Backspace, .Delete, .Left, .Right, .Home, .End, .Insert, .Page_Up, .Page_Down, .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12:
		return false
	}
	return true
}

completion_choose :: proc(a: ^App, i: int) {
	c := &a.completion
	if i < 0 || i >= len(c.items) {
		return
	}
	item := c.items[i]
	tui.editor_replace(&a.editor, c.start, c.end, item.insert)
	c.active = false
	clear(&c.items)
	c.selected = 0
}

// draw_completion draws the list over the message box.
draw_completion :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	c := &a.completion
	if !c.active {
		return
	}
	w := 0
	for it in c.items {
		w = max(w, tui.string_width(it.label))
	}
	w = min(w + 2, g.composer.w)
	n := min(len(c.items), 2 * COMPLETION_MAX)
	top := max(g.composer.y - n, 1)
	for it, i in c.items {
		if i >= n {
			break
		}
		style := theme.selected if i == c.selected else theme.bar
		y := top + i
		tui.fill(b, {g.composer.x, y, w, 1}, style)
		tui.put_string(b, g.composer.x + 1, y, it.label, style, g.composer.x + w)
		append(&a.hits, Hit{{g.composer.x, y, w, 1}, .Completion, u64(i), ""})
	}
}
