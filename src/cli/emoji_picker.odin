package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import "client:conn"
import "common:proto"
import "tui"

// The emoji picker: to react to a message, or to put an emoji in the message.
// It has every emoji (common/proto/emoji_table.odin, the window client's), in
// categories you go through with Tab, and a box to find them: what is typed is
// looked for in every shortcode (`tada` finds 🎉, `thumb` finds 👍 and 👎). The
// server's own emoji come after the common ones and are written as `:name:`.

Picker_Item :: struct {
	label: string, // what is drawn: the emoji, or :name:
	send:  string, // what is sent or inserted
	names: string, // its shortcodes, for the footer
}

// The category shown when the picker opens, and the places before the unicode ones.
CATEGORY_COMMON :: -2
CATEGORY_CUSTOM :: -1

// The emoji most reactions are made of.
@(private = "file")
COMMON := [?]rune {
	0x1F44D, 0x1F44E, 0x2764, 0x1F602, 0x1F62E, 0x1F622, 0x1F389, 0x1F64F,
	0x1F440, 0x1F525, 0x2705, 0x274C, 0x1F4AF, 0x1F914, 0x1F44F, 0x1F600,
	0x1F60D, 0x1F60E, 0x1F64C, 0x1F4AA, 0x1F680, 0x2B50, 0x1F605, 0x1F91D,
}

// open_picker opens the picker to react to a message.
open_picker :: proc(a: ^App, msg: proto.Msg_Id) {
	dialog_close(a)
	a.dialog.kind, a.dialog.msg, a.dialog.category = .Picker, msg, CATEGORY_COMMON
}

// open_emoji_insert opens the picker to put an emoji in the message being written.
open_emoji_insert :: proc(a: ^App) {
	dialog_close(a)
	a.dialog.kind, a.dialog.msg, a.dialog.category = .Picker, 0, CATEGORY_COMMON
}

@(private = "file")
item_of :: proc(e: proto.Emoji) -> Picker_Item {
	s := utf8.runes_to_string({e.r}, context.temp_allocator)
	return {label = s, send = s, names = e.names}
}

@(private = "file")
emoji_entry :: proc(r: rune) -> (proto.Emoji, bool) {
	if i, ok := proto.emoji_index(r); ok {
		return proto.EMOJI[i], true
	}
	return {}, false
}

// The categories in the order Tab goes through them: the common emoji, the
// server's own (if it has any), then the unicode ones.
picker_categories :: proc(v: ^conn.View) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	append(&out, CATEGORY_COMMON)
	if len(v.emoji.names) > 0 {
		append(&out, CATEGORY_CUSTOM)
	}
	for cat in proto.Emoji_Category {
		append(&out, int(cat))
	}
	return out[:]
}

picker_category_name :: proc(cat: int) -> string {
	switch cat {
	case CATEGORY_COMMON: return "Common"
	case CATEGORY_CUSTOM: return "This server's"
	}
	return fmt.tprint(proto.Emoji_Category(cat))
}

// picker_items are what the picker shows now: what the typed text finds, or
// else the category. Call with the View locked.
picker_items :: proc(a: ^App) -> []Picker_Item {
	v := a.view
	items := make([dynamic]Picker_Item, context.temp_allocator)
	query := strings.to_lower(strings.trim_space(tui.editor_text(&a.dialog.fields[0])), context.temp_allocator)
	query = strings.trim(query, ":")
	if query != "" {
		// Exact shortcodes first, then those that start with it, then the rest.
		for rank in 0 ..< 3 {
			for name in v.emoji.names {
				lower := strings.to_lower(name, context.temp_allocator)
				if match_rank(lower, query) == rank {
					append(&items, Picker_Item{label = fmt.tprintf(":%s:", name), send = fmt.tprintf(":%s:", name), names = name})
				}
			}
			for e in proto.EMOJI {
				names := e.names
				best := 3
				for code in strings.split_iterator(&names, " ") {
					best = min(best, match_rank(code, query))
				}
				if best == rank {
					append(&items, item_of(e))
				}
			}
		}
		return items[:]
	}
	switch cat := a.dialog.category; cat {
	case CATEGORY_COMMON:
		for r in COMMON {
			if e, ok := emoji_entry(r); ok {
				append(&items, item_of(e))
			}
		}
	case CATEGORY_CUSTOM:
		for name in v.emoji.names {
			append(&items, Picker_Item{label = fmt.tprintf(":%s:", name), send = fmt.tprintf(":%s:", name), names = name})
		}
	case:
		for e in proto.EMOJI {
			if int(e.category) == cat {
				append(&items, item_of(e))
			}
		}
	}
	return items[:]
}

// match_rank says how a shortcode matches what was typed: 0 for the same, 1 for
// starting with it, 2 for having it inside, 3 for not at all.
@(private = "file")
match_rank :: proc(code, query: string) -> int {
	switch {
	case code == query: return 0
	case strings.has_prefix(code, query): return 1
	case strings.contains(code, query): return 2
	}
	return 3
}

// picker_geometry: where the grid goes, how wide a cell is and how many columns
// and visible rows there are.
@(private = "file")
Picker_Layout :: struct {
	box:             tui.Rect,
	cell_w, columns: int,
	rows:            int,
}

@(private = "file")
picker_layout :: proc(b: ^tui.Buffer, items: []Picker_Item) -> Picker_Layout {
	l: Picker_Layout
	l.box = dialog_rect(b, min(b.w - 4, 76), min(b.h - 2, 22))
	l.cell_w = 4
	for it in items {
		l.cell_w = max(l.cell_w, tui.string_width(it.label) + 2)
	}
	l.columns = max((l.box.w - 4) / l.cell_w, 1)
	l.rows = max(l.box.h - 7, 1)
	return l
}

draw_picker :: proc(a: ^App, b: ^tui.Buffer) {
	d := &a.dialog
	items := picker_items(a)
	l := picker_layout(b, items)
	r := l.box
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, "React with" if d.msg != 0 else "Emoji")

	// The box to find them in.
	tui.put_string(b, r.x + 2, r.y + 1, "Find", theme.dim)
	fx, fw := r.x + 8, r.w - 10
	tui.fill(b, {fx, r.y + 1, fw, 1}, theme.reaction)
	text := tui.editor_text(&d.fields[0])
	tui.put_string(b, fx, r.y + 1, tui.cut_to_width(text, fw - 1), theme.reaction, fx + fw)
	a.cursor, a.cursor_shown = {fx + min(tui.string_width(text), fw - 1), r.y + 1}, true

	// The category (Tab), or how many were found.
	y := r.y + 2
	if text == "" {
		cat := fmt.tprintf("◂ %s ▸   Tab: next kind", picker_category_name(d.category))
		tui.put_string(b, r.x + 2, y, cat, {attrs = {.Bold}}, r.x + r.w - 1)
		append(&a.hits, Hit{{r.x + 2, y, 3, 1}, .Picker_Tab, 0, ""})
		append(&a.hits, Hit{{r.x + 3 + tui.string_width(picker_category_name(d.category)), y, 3, 1}, .Picker_Tab, 1, ""})
	} else {
		tui.put_string(b, r.x + 2, y, fmt.tprintf("%d found", len(items)), theme.dim, r.x + r.w - 1)
	}

	// The grid, scrolled to keep the one picked in view.
	d.sel = clamp(d.sel, 0, max(len(items) - 1, 0))
	sel_row := d.sel / l.columns
	d.top = clamp(d.top, max(sel_row - l.rows + 1, 0), sel_row)
	gy := r.y + 3
	for row in 0 ..< l.rows {
		for col in 0 ..< l.columns {
			i := (d.top + row) * l.columns + col
			if i >= len(items) {
				break
			}
			cell := tui.Rect{r.x + 2 + col * l.cell_w, gy + row, l.cell_w, 1}
			style := theme.selected if i == d.sel else tui.Style{}
			tui.fill(b, cell, style)
			tui.put_string(b, cell.x + 1, cell.y, items[i].label, style, cell.x + cell.w)
			append(&a.hits, Hit{cell, .Emoji, u64(i), ""})
		}
	}
	if len(items) == 0 {
		tui.put_string(b, r.x + 2, gy, "Nothing found.", theme.dim, r.x + r.w - 1)
	}

	// What the one picked is called.
	if d.sel < len(items) {
		it := items[d.sel]
		names, _ := strings.replace_all(it.names, " ", "  ", context.temp_allocator)
		tui.put_string(b, r.x + 2, r.y + r.h - 3, fmt.tprintf("%s  :%s:", it.label, names) if !strings.has_prefix(it.send, ":") else it.send, {}, r.x + r.w - 1)
	}
	hint := "Type to find   Arrows: pick   Enter: react   Esc: close" if d.msg != 0 else "Type to find   Arrows: pick   Enter: insert   Esc: close"
	tui.put_string(b, r.x + 2, r.y + r.h - 2, hint, theme.dim, r.x + r.w - 1)
}

// picker_move moves the pick by cells (or by rows, times the columns).
picker_move :: proc(a: ^App, by: int, rows := false) {
	d := &a.dialog
	items := picker_items(a)
	columns := max(picker_columns(a), 1)
	d.sel = clamp(d.sel + by * (columns if rows else 1), 0, max(len(items) - 1, 0))
}

// picker_columns is how many emoji are in a row now. It is worked out from the
// screen the picker was last drawn on.
picker_columns :: proc(a: ^App) -> int {
	if a.frame == nil {
		return 8
	}
	return picker_layout(a.frame, picker_items(a)).columns
}

// picker_category_step goes to the next (or previous) kind of emoji.
@(private = "file")
picker_category_step :: proc(a: ^App, dir: int) {
	d := &a.dialog
	cats := picker_categories(a.view)
	at := 0
	for c, i in cats {
		if c == d.category {
			at = i
		}
	}
	d.category = cats[(at + dir + len(cats)) %% len(cats)]
	d.sel, d.top = 0, 0
}

picker_key :: proc(a: ^App, k: tui.Key_Event) {
	d := &a.dialog
	switch {
	case k.key == .Escape:
		if tui.editor_text(&d.fields[0]) != "" {
			tui.editor_clear(&d.fields[0])
			d.sel, d.top = 0, 0
		} else {
			dialog_close(a)
		}
	case k.key == .Enter:
		picker_choose(a, d.sel)
	case k.key == .Left: picker_move(a, -1)
	case k.key == .Right: picker_move(a, 1)
	case k.key == .Up: picker_move(a, -1, rows = true)
	case k.key == .Down: picker_move(a, 1, rows = true)
	case k.key == .Page_Up: picker_move(a, -3, rows = true)
	case k.key == .Page_Down: picker_move(a, 3, rows = true)
	case k.key == .Tab && .Shift in k.mods: picker_category_step(a, -1)
	case k.key == .Tab: picker_category_step(a, 1)
	case:
		if tui.editor_key(&d.fields[0], k) {
			d.sel, d.top = 0, 0
		}
	}
}

// picker_choose reacts to the message with the emoji at i (taking the reaction
// back if it is ours already), or puts it in the message being written. Call with
// the View locked.
picker_choose :: proc(a: ^App, i: int) {
	items := picker_items(a)
	if i < 0 || i >= len(items) {
		return
	}
	it := items[i]
	send := strings.clone(it.send, context.temp_allocator)
	msg := a.dialog.msg
	dialog_close(a)
	if msg != 0 {
		react(a, msg, send)
		return
	}
	// A custom emoji is followed by a space so that the next word is not part of it.
	tui.editor_insert(&a.editor, send if !strings.has_prefix(send, ":") else strings.concatenate({send, " "}, context.temp_allocator))
	a.focus = .Composer
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
	push(a, conn.React_Command{id = id, emoji = strings.clone(emoji), on = on, typed = strings.has_prefix(emoji, ":")})
}
