package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Completing a mention or an emoji in a composer. While the word the cursor
is at the end of starts with `@` (at the start of a word), a list over the
composer shows the accounts it could be: by username or display name,
those here first, at most COMPLETION_MAX. Choosing completes the word to
`@username ` (conn/mentions.odin turns it into a token when the message
is sent). Under them are the roles that can be mentioned whose names
start so, at most ROLE_COMPLETION_MAX, each in its colour and marked as
a role, so one called what an account is called is told apart from it.
A role's name may have spaces in it, so the list stays open past them
while what's after the `@` is the start of one. Choosing one completes
to `@role name `, or to its token if `@role name` would be the account's
(conn/mentions.odin). A word of at least two more characters after a `:`
lists the emoji whose shortcode starts so, the server's own first; choosing puts
the emoji in its place (a Unicode one as its character, the server's as
its `:name:`). Up and Down move in the list, Tab or Enter choose, Escape
closes it until the word changes; or a click.

The keys are taken before the text box sees them (completion_keys),
from what was worked out last frame; what's typed is worked out again
after the box has had it (completion_update), and the list is drawn
over everything else (completion_window).

*/

COMPLETION_MAX :: 6
ROLE_COMPLETION_MAX :: 3

Completion_Item :: struct {
	insert: string, // what the word becomes; owned (the list is used the frame after it's made)
	label:  string, // what the list shows; owned
	// For sorting mentions: the username, and whether the account is here.
	key:    string,
	here:   bool,
	color:  u32, // a role's, to show it in; 0 for the usual
}

UI_Completion :: struct {
	active:    bool,
	box:       mu.Id, // the composer's text box it's for
	thread:    int, // ... and which composer that is (Composer.thread)
	start:     int, // where the `@word` is in its text, and where it ends:
	end:       int, // the cursor
	items:     [dynamic]Completion_Item,
	selected:  int,
	anchor:    mu.Rect, // the text box, to put the list over
	// The word Escape closed it for, until it isn't that any more.
	dismissed: string, // owned
}

ui_completion_destroy :: proc(ui: ^UI) {
	items_clear(&ui.completion)
	delete(ui.completion.items)
	delete(ui.completion.dismissed)
	ui.completion = {}
}

/*
completion_keys takes the list's keys before the composer's text box
sees them, and does what they say. Call before laying the box out.
*/
completion_keys :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
	cm := &ui.completion
	box := mu.get_id(ctx, uintptr(&c.buf[0]))
	if !cm.active || cm.box != box || ctx.focus_id != box {
		return
	}
	n := len(cm.items)
	switch {
	case .Escape in ui.keys:
		ui.keys -= {.Escape} // not for the composer as well
		delete(cm.dismissed)
		cm.dismissed = strings.clone(string(c.buf[cm.start:cm.end]))
		cm.active = false
	case .Up in ui.keys:
		ui.keys -= {.Up}
		cm.selected = (cm.selected + n - 1) % n
	case .Down in ui.keys:
		ui.keys -= {.Down}
		cm.selected = (cm.selected + 1) % n
	case .Tab in ui.keys, .RETURN in ctx.key_pressed_bits:
		ui.keys -= {.Tab}
		ctx.key_pressed_bits -= {.RETURN}
		completion_choose(ui, c, cm.selected)
	}
}

// completion_choose completes the word to item `i`.
@(private = "file")
completion_choose :: proc(ui: ^UI, c: Composer, i: int) {
	cm := &ui.completion
	if i < 0 || i >= len(cm.items) || cm.end > c.len^ {
		return
	}
	insert := cm.items[i].insert
	rest := strings.clone(string(c.buf[cm.end:c.len^]), context.temp_allocator)
	if cm.start + len(insert) + len(rest) > len(c.buf) {
		return // no room
	}
	n := copy(c.buf[cm.start:], insert)
	n += copy(c.buf[cm.start + n:], rest)
	c.len^ = cm.start + n
	focus_composer(ui, c, cm.start + len(insert))
	cm.active = false
}

/*
completion_update works out the list from what the box now has: whether
the cursor is at the end of an `@word`, and who that could be. Call
after laying the box out, with the View locked.
*/
completion_update :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
	v := ui.view
	cm := &ui.completion
	box := mu.get_id(ctx, uintptr(&c.buf[0]))
	if ctx.focus_id != box {
		if cm.box == box {
			cm.active = false
		}
		return
	}
	cm.box = box
	cm.thread = c.thread
	cm.anchor = ctx.last_rect
	cursor := c.len^
	if ctx.textbox_state.id == u64(box) {
		cursor = clamp(ctx.textbox_state.selection[0], 0, c.len^)
	}
	text := string(c.buf[:c.len^])
	start := cursor
	for start > 0 && word_char(text[start - 1]) {
		start -= 1
	}
	trigger: u8 = text[start - 1] if start > 0 else 0
	// Past a space, only a role's name.
	spaced := false
	if (trigger != '@' && trigger != ':') ||
	   (start > 1 && !strings.is_space(rune(text[start - 2]))) ||
	   (trigger == ':' && cursor - start < 2) {
		at := role_word_start(v, text, cursor)
		if at < 0 {
			cm.active = false
			delete(cm.dismissed)
			cm.dismissed = ""
			return
		}
		start, trigger, spaced = at + 1, '@', true
	}
	start -= 1
	word := text[start:cursor]
	if word == cm.dismissed {
		cm.active = false
		return
	}
	if cm.active && (cm.start != start || cm.end != cursor) {
		cm.selected = 0
	}
	cm.start, cm.end = start, cursor
	prefix := strings.to_lower(word[1:], context.temp_allocator)

	items_clear(cm)
	if trigger == ':' {
		emoji_items(ui, prefix)
		cm.active = len(cm.items) > 0
		cm.selected = clamp(cm.selected, 0, max(len(cm.items) - 1, 0))
		return
	}
	for id, acc in v.accounts {
		if spaced || id == v.me || acc.flags & {.Disabled, .Deleted} != {} {
			continue
		}
		if strings.has_prefix(acc.username, prefix) ||
		   strings.has_prefix(strings.to_lower(acc.display, context.temp_allocator), prefix) {
			item := Completion_Item {
				insert = strings.concatenate({"@", acc.username, " "}),
				label  = strings.concatenate({"@", acc.username, "   ", acc.display}),
				key    = acc.username,
			}
			for _, u in v.users {
				item.here ||= u.account == id
			}
			append(&cm.items, item)
		}
	}
	// Those who are here first, then by username.
	slice.sort_by(cm.items[:], proc(a, b: Completion_Item) -> bool {
		if a.here != b.here {
			return a.here
		}
		return a.key < b.key
	})
	for len(cm.items) > COMPLETION_MAX {
		item := pop(&cm.items)
		delete(item.insert)
		delete(item.label)
	}
	role_items(ui, prefix)
	if !spaced &&
	   .Mention_Everyone in v.permissions &&
	   strings.has_prefix(proto.MENTION_EVERYONE, prefix) {
		append(
			&cm.items,
			Completion_Item {
				insert = strings.clone("@" + proto.MENTION_EVERYONE + " "),
				label = strings.clone("@" + proto.MENTION_EVERYONE + "   everyone here"),
			},
		)
	}
	cm.active = len(cm.items) > 0
	cm.selected = clamp(cm.selected, 0, max(len(cm.items) - 1, 0))
}

/*
role_word_start is where the `@` is that a role's name the cursor is in
starts after, when there's a space in what's been typed of it; -1 if the
cursor isn't in one. Call with the View locked.
*/
@(private = "file")
role_word_start :: proc(v: ^conn.View, text: string, cursor: int) -> int {
	for at := cursor - 1; at >= 0 && cursor - at <= proto.MAX_ROLE_NAME + 1; at -= 1 {
		if text[at] != '@' || (at > 0 && !strings.is_space(rune(text[at - 1]))) {
			continue
		}
		typed := text[at + 1:cursor]
		if strings.index_byte(typed, ' ') < 0 {
			return -1 // a word, which the usual list is for
		}
		for r in v.roles {
			if conn.role_mentionable(r) &&
			   len(r.name) >= len(typed) &&
			   strings.equal_fold(r.name[:len(typed)], typed) {
				return at
			}
		}
		return -1
	}
	return -1
}

// role_items lists the roles that can be mentioned whose name starts
// with `prefix` (in lower case), in the roles' order. Call with the View
// locked.
@(private = "file")
role_items :: proc(ui: ^UI, prefix: string) {
	v := ui.view
	cm := &ui.completion
	n := 0
	for r in v.roles {
		if n == ROLE_COMPLETION_MAX {
			break
		}
		if !conn.role_mentionable(r) ||
		   !strings.has_prefix(strings.to_lower(r.name, context.temp_allocator), prefix) {
			continue
		}
		insert: string
		if conn.role_name_shadowed(v.accounts, r.name) {
			insert = strings.concatenate({proto.role_mention_token(r.id), " "})
		} else {
			insert = strings.concatenate({"@", r.name, " "})
		}
		append(
			&cm.items,
			Completion_Item {
				insert = insert,
				label = strings.concatenate({"@", r.name, "   role"}),
				color = r.color,
			},
		)
		n += 1
	}
}

// emoji_items lists the emoji whose name starts with `prefix`: the
// server's own, then Unicode's by any of their shortcodes.
@(private = "file")
emoji_items :: proc(ui: ^UI, prefix: string) {
	cm := &ui.completion
	for name in ui.view.emoji.names {
		if len(cm.items) < COMPLETION_MAX && strings.has_prefix(name, prefix) {
			code := strings.concatenate({":", name, ":"})
			append(&cm.items, Completion_Item{insert = code, label = strings.clone(code)})
		}
	}
	for e in proto.EMOJI {
		if len(cm.items) >= COMPLETION_MAX {
			break
		}
		names := e.names
		for code in strings.split_iterator(&names, " ") {
			if strings.has_prefix(code, prefix) {
				char := utf8.runes_to_string({e.r})
				append(
					&cm.items,
					Completion_Item{insert = char, label = fmt.aprintf("%s   :%s:", char, code)},
				)
				break
			}
		}
	}
}

// items_clear empties the list, and lets go of its strings.
@(private = "file")
items_clear :: proc(cm: ^UI_Completion) {
	for item in cm.items {
		delete(item.insert)
		delete(item.label)
	}
	clear(&cm.items)
}

// word_char is whether a byte may be in the word being completed: a
// username's, or an emoji's name (which may have `+`, as `+1` does).
@(private = "file")
word_char :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '-', '+':
		return true
	}
	return false
}

@(private = "file")
COMPLETION_WINDOW :: "completion"

// completion_window draws the list over the composer it's for, if it's
// open. A click on one chooses it.
completion_window :: proc(ui: ^UI) {
	ctx := &ui.ctx
	cm := &ui.completion
	if !cm.active || len(cm.items) == 0 {
		return
	}
	row := ctx.style.size.y + 2 * ctx.style.padding
	h := i32(len(cm.items)) * (row + ctx.style.spacing) + ctx.style.spacing + 2 * ctx.style.padding
	w := min(cm.anchor.w, 320)
	rect := mu.Rect{cm.anchor.x, cm.anchor.y - h - 2, w, h}
	if cnt := mu.get_container(ctx, COMPLETION_WINDOW); cnt != nil {
		cnt.rect = rect
		cnt.open = true
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(
		ctx,
		COMPLETION_WINDOW,
		rect,
		{.NO_TITLE, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE},
	) {
		return
	}
	defer mu.end_window(ctx)
	for item, i in cm.items {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		label := item.label
		saved := ctx.style.colors[.BUTTON]
		saved_text := ctx.style.colors[.TEXT]
		if i == cm.selected {
			ctx.style.colors[.BUTTON] = ctx.style.colors[.BUTTON_FOCUS]
		}
		if item.color != 0 {
			ctx.style.colors[.TEXT] = role_rgb(item.color)
		}
		if .SUBMIT in stable_button(ctx, "item", label) {
			completion_choose(ui, composer_of(ui, cm.thread), i)
		}
		ctx.style.colors[.BUTTON] = saved
		ctx.style.colors[.TEXT] = saved_text
	}
}
