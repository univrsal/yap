package main

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

import "client:conn"
import "client:richtext"
import "common:proto"
import "tui"

// The messages of a conversation as rows of text, laid out for a width: what the
// timeline pane draws. It is worked out from the View (with its mutex held)
// and kept until something it depends on changes (Timeline_Layout.key).
//
// This is the terminal's version of what the window client's ui_timeline.odin
// decides (where a day starts, which messages are merged under the one before,
// where the "new messages" line goes), without the pixel heights that make that
// file large; see docs/design/cli-client.md, E3.

Row_Kind :: enum u8 {
	Day, // a day's line
	New_Messages, // the line above the first unread message
	Reply_To, // "in reply to" above the first of a thread's replies
	Head, // the first row of a message: time, name and the start of the text
	Body, // the rest of a message's text
	Files,
	Image, // a row of a picture
	Reactions,
	Thread, // "3 replies" under a thread's root
	System,
	Pending, // a message of ours on its way
	Notice, // "loading", "start of the conversation"
}

Row :: struct {
	kind:   Row_Kind,
	msg:    proto.Msg_Id, // the message this belongs to, 0 for none
	segs:   []Seg,
	text_x: int, // the column the text starts at (what is left of it is the time and name)
	chips:  []Chip, // the reactions on a .Reactions row
}

// A reaction as it is drawn: where it is in the row, and whether we made it.
Chip :: struct {
	emoji:      string,
	start, end: int, // columns, from the row's left edge
	me:         bool,
}

// What the rows were worked out for; they are worked out again when it changes.
Layout_Key :: struct {
	conv, root:  proto.Msg_Id,
	width:       int,
	revision:    int,
	unread_from: proto.Msg_Id,
	accounts:    int,
	roots:       int,
	outbox:      int,
	saves:       u64, // what is being saved, and how far
	pictures:    int, // how many are decoded
	me:          proto.Account_Id,
	loading:     bool,
	have_oldest: bool,
	valid:       bool,
}

// A picture a message has that has not arrived: which message and file, and its blob.
Want :: struct {
	msg:   proto.Msg_Id,
	index: int,
	blob:  proto.Blob_Id,
}

Timeline_Layout :: struct {
	arena:    virtual.Arena,
	rows:     [dynamic]Row,
	key:      Layout_Key,
	// The pictures to draw in messages (nil to draw none), and those that are
	// still to be fetched.
	pictures: ^Pictures,
	wants:    [dynamic]Want,
}

layout_destroy :: proc(l: ^Timeline_Layout) {
	delete(l.rows)
	delete(l.wants)
	virtual.arena_destroy(&l.arena)
	l^ = {}
}

// layout_update works the rows out again if what they depend on changed. `tz` is
// the time zone times are shown in (nil for UTC). `unread_from` is the newest
// message that has been read, if the messages after it are to be told apart
// (0 for none). Call with the View locked.
layout_update :: proc(
	l: ^Timeline_Layout,
	v: ^conn.View,
	key: conn.Timeline_Key,
	width: int,
	tz: ^datetime.TZ_Region,
	unread_from: proto.Msg_Id,
) {
	tl, have := &v.timelines[key]
	want := Layout_Key {
		conv        = proto.Msg_Id(key.conv),
		root        = key.root,
		width       = width,
		unread_from = unread_from,
		accounts    = len(v.accounts),
		roots       = len(v.roots),
		saves       = saves_signature(v),
		pictures    = len(l.pictures.by_blob) if l.pictures != nil else 0,
		outbox      = len(v.outbox),
		me          = v.me,
		valid       = true,
	}
	if have {
		want.revision, want.loading, want.have_oldest = tl.revision, tl.loading, tl.have_oldest
	}
	if l.key == want {
		return
	}
	l.key = want
	clear(&l.rows)
	// The array of rows is not in the arena (the arena is emptied for each
	// layout), so it gets its memory before the allocator is switched.
	reserve(&l.rows, 64)
	clear(&l.wants)
	reserve(&l.wants, 8)
	if l.arena.curr_block == nil {
		_ = virtual.arena_init_growing(&l.arena)
	} else {
		virtual.arena_free_all(&l.arena)
	}
	context.allocator = virtual.arena_allocator(&l.arena)
	if width < 10 {
		return
	}
	build_rows(l, v, key, tl if have else nil, width, tz, unread_from)
}

@(private = "file")
Local_Time :: struct {
	hour, minute: int,
	day:          i64, // a number for the day, to tell days apart
	label:        string, // "Thu 6 Nov 2026"
}

@(private = "file")
local_time :: proc(ms: proto.Unix_Ms, tz: ^datetime.TZ_Region) -> Local_Time {
	t := time.unix(i64(ms) / 1000, 0)
	dt, _ := time.time_to_datetime(t)
	if tz != nil {
		if local, ok := timezone.datetime_to_tz(dt, tz); ok {
			dt = local
		}
	}
	ordinal, _ := datetime.date_to_ordinal(dt.date)
	days := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return {
		hour = int(dt.hour),
		minute = int(dt.minute),
		day = i64(ordinal),
		label = fmt.aprintf(
			"%s %d %s %d",
			days[int(datetime.day_of_week(ordinal))],
			dt.day,
			months[dt.month - 1],
			dt.year,
		),
	}
}

@(private = "file")
build_rows :: proc(
	l: ^Timeline_Layout,
	v: ^conn.View,
	key: conn.Timeline_Key,
	tl: ^conn.View_Timeline,
	width: int,
	tz: ^datetime.TZ_Region,
	unread_from: proto.Msg_Id,
) {
	// The name column: as wide as the longest name shown, within limits.
	name_w := 4
	if tl != nil {
		for m in tl.messages {
			name_w = max(name_w, tui.string_width(sender_name(v, m)))
		}
	}
	name_w = min(name_w, max(width / 4, 4), 16)
	text_x := 5 + 1 + name_w + 1
	text_w := max(width - text_x, 8)
	in_thread := key.root != 0

	if tl == nil || (tl.loading && len(tl.messages) == 0) {
		add_row(l, .Notice, 0, 0, {{"loading...", theme.dim}})
		return
	}
	if tl.have_oldest {
		add_row(l, .Notice, 0, 0, {{"- start of the conversation -", theme.dim}})
	} else if tl.loading {
		add_row(l, .Notice, 0, 0, {{"loading older messages...", theme.dim}})
	}

	// A thread starts with the message it is about.
	if in_thread {
		if r, ok := v.roots[key.root]; ok {
			lt := local_time(r.msg.time, tz)
			add_message(l, v, r.msg, lt, false, name_w, text_x, text_w, true)
			delete(lt.label)
			word := "reply" if r.msg.reply_count == 1 else "replies"
			add_row(l, .Day, 0, 0, {{rule_text(fmt.tprintf("%d %s", r.msg.reply_count, word), width), theme.dim}})
		} else {
			add_row(l, .Notice, 0, 0, {{"loading the message...", theme.dim}})
		}
	}
	prev: conn.View_Message
	prev_day := i64(-1)
	for m, i in tl.messages {
		lt := local_time(m.time, tz)
		new_day := lt.day != prev_day && !in_thread
		new_line := unread_from != 0 && i > 0 && prev.id <= unread_from && m.id > unread_from
		if i == 0 && unread_from != 0 && tl.have_oldest && m.id > unread_from {
			new_line = true
		}
		if new_day {
			add_row(l, .Day, 0, 0, {{rule_text(lt.label, width), theme.dim}})
		}
		if new_line {
			add_row(l, .New_Messages, 0, 0, {{rule_text("new messages", width), theme.unread_rule}})
		}
		reply_line := !in_thread && m.thread_root != 0 && (i == 0 || m.thread_root != prev.thread_root)
		if reply_line {
			add_row(l, .Reply_To, m.id, text_x, reply_segs(v, m.thread_root, text_x, width))
		}
		merged :=
			!new_day &&
			!new_line &&
			!reply_line &&
			i > 0 &&
			m.sender == prev.sender &&
			m.thread_root == prev.thread_root &&
			m.persona.name == prev.persona.name &&
			m.kind == .Text &&
			prev.kind == .Text &&
			m.edited == 0 &&
			.Deleted not_in m.flags &&
			lt.minute == prev_minute(prev, tz) &&
			lt.hour == prev_hour(prev, tz)
		add_message(l, v, m, lt, merged, name_w, text_x, text_w, in_thread)
		prev, prev_day = m, lt.day
		delete(lt.label)
	}
	if tl.have_newest {
		for p in v.outbox {
			if p.conv == key.conv && p.root == key.root {
				text := p.text
				if p.kind == .File {
					text = fmt.aprintf("the file %s", p.text)
				}
				for f in p.files {
					text = fmt.aprintf("%s\n📎 %s  %d%%", text, f.name, int(f.done * 100 / max(f.size, 1)))
				}
				lines := styled_lines(text, nil, text_w, theme.dim)
				for line, j in lines {
					first := Seg{"sending", theme.dim} if j == 0 else Seg{"", theme.dim}
					lead := fmt.aprintf("%-*s", text_x, first.text)
					add_row(l, .Pending, 0, text_x, concat_segs({{lead, theme.dim}}, line))
				}
			}
		}
	}
}

@(private = "file")
prev_minute :: proc(m: conn.View_Message, tz: ^datetime.TZ_Region) -> int {
	lt := local_time(m.time, tz)
	defer delete(lt.label)
	return lt.minute
}

@(private = "file")
prev_hour :: proc(m: conn.View_Message, tz: ^datetime.TZ_Region) -> int {
	lt := local_time(m.time, tz)
	defer delete(lt.label)
	return lt.hour
}

@(private = "file")
add_row :: proc(l: ^Timeline_Layout, kind: Row_Kind, msg: proto.Msg_Id, text_x: int, segs: []Seg) {
	append(&l.rows, Row{kind = kind, msg = msg, segs = clone_segs(segs), text_x = text_x})
}

@(private = "file")
clone_segs :: proc(segs: []Seg) -> []Seg {
	out := make([]Seg, len(segs))
	copy(out, segs)
	return out
}

@(private = "file")
concat_segs :: proc(a, b: []Seg) -> []Seg {
	out := make([]Seg, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

// rule_text is a line across the width with a label in it: "── label ───────".
@(private = "file")
rule_text :: proc(label: string, width: int) -> string {
	left := 2
	right := max(width - left - tui.string_width(label) - 2, 2)
	return fmt.aprintf("%s %s %s", strings.repeat("─", left), label, strings.repeat("─", right))
}

// sender_name is who a message is from, as shown.
sender_name :: proc(v: ^conn.View, m: conn.View_Message) -> string {
	if .Persona in m.flags && m.persona.name != "" {
		return m.persona.name
	}
	if m.kind == .System {
		return "*"
	}
	if acc, ok := v.accounts[m.sender]; ok {
		return acc.display if acc.display != "" else acc.username
	}
	return "someone"
}

shown_text :: proc(v: ^conn.View, m: conn.View_Message) -> (string, []richtext.Mention_Span) {
	return richtext.mentions_display(m.text, v.accounts, v.roles[:], v.me)
}

@(private = "file")
reply_segs :: proc(v: ^conn.View, root: proto.Msg_Id, text_x: int, width: int) -> []Seg {
	lead := strings.repeat(" ", max(text_x - 2, 0))
	r, have := v.roots[root]
	segs := make([]Seg, 2)
	segs[0] = {lead, {}}
	if !have {
		segs[1] = {"↪ a reply in a thread", theme.dim}
		return segs
	}
	shown, _ := shown_text(v, r.msg)
	one := richtext.one_line(shown)
	body := fmt.aprintf("↪ %s: %s", sender_name(v, r.msg), one)
	body = tui.cut_to_width(body, max(width - text_x, 4))
	segs[1] = {body, theme.dim}
	return segs
}

@(private = "file")
add_message :: proc(
	l: ^Timeline_Layout,
	v: ^conn.View,
	m: conn.View_Message,
	lt: Local_Time,
	merged: bool,
	name_w, text_x, text_w: int,
	in_thread: bool,
) {
	// Time and name, or blanks for a message merged under the one above.
	head: []Seg
	if merged {
		head = {{strings.repeat(" ", text_x), {}}}
	} else {
		name := tui.cut_to_width(sender_name(v, m), name_w)
		pad := strings.repeat(" ", name_w - tui.string_width(name))
		nstyle := theme.own_name if m.sender == v.me && m.kind != .System else name_style(u64(m.sender))
		head = {
			{fmt.aprintf("%02d:%02d ", lt.hour, lt.minute), theme.dim},
			{name, nstyle},
			{strings.concatenate({pad, " "}), {}},
		}
	}

	// The text.
	lines: [][]Seg
	kind := Row_Kind.Body
	switch {
	case .Deleted in m.flags:
		lines = {{{"message deleted", {fg = theme.dim.fg, attrs = {.Italic}}}}}
	case m.kind == .System:
		lines = styled_lines(conn.system_line(v, m), nil, text_w, theme.dim)
		kind = .System
	case m.kind == .File && len(m.files) == 0:
		lines = {{{fmt.aprintf("📎 %s  %s", m.text, human_size(m.file_size)), {}}}}
	case:
		shown, spans := shown_text(v, m)
		lines = styled_lines(shown, spans, text_w, {})
	}
	if len(lines) == 0 {
		lines = {{}}
	}
	for line, i in lines {
		segs: []Seg
		if i == 0 {
			segs = concat_segs(head, line)
		} else {
			segs = concat_segs({{strings.repeat(" ", text_x), {}}}, line)
		}
		row_kind := kind if i > 0 || kind == .System else .Head
		if i == len(lines) - 1 {
			tail := make([dynamic]Seg, context.temp_allocator)
			if m.edited != 0 && .Deleted not_in m.flags {
				append(&tail, Seg{" (edited)", theme.dim})
			}
			if .Pinned in m.flags {
				append(&tail, Seg{" 📌", theme.dim})
			}
			if len(tail) > 0 {
				segs = concat_segs(segs, tail[:])
			}
		}
		add_row(l, row_kind, m.id, text_x, segs)
	}

	pad := strings.repeat(" ", text_x)
	for f in m.files {
		text := fmt.aprintf("📎 %s  %s", f.name, human_size(f.size))
		segs := []Seg{{pad, {}}, {text, {}}, {"", {}}}
		if sv, saving := v.saves[f.blob]; saving && f.blob != 0 {
			switch sv.state {
			case .Asking, .Receiving:
				pct := int(sv.done * 100 / max(sv.size, 1))
				segs[2] = {fmt.aprintf("  ⇩ %d%%", pct), theme.mention}
			case .Done:
				segs[2] = {fmt.aprintf("  ✔ saved to %s", sv.path), theme.online}
			case .Failed:
				segs[2] = {"  ✘ could not be saved", theme.error}
			case .Cancelled:
				segs[2] = {"  (cancelled)", theme.dim}
			}
		}
		add_row(l, .Files, m.id, text_x, segs)
	}
	if l.pictures != nil && .Deleted not_in m.flags {
		for f, i in m.files {
			if !is_picture_file(f) {
				continue
			}
			pic, here := l.pictures.by_blob[f.blob]
			switch {
			case here && !pic.failed:
				for row in 0 ..< pic.rows {
					add_row(l, .Image, m.id, text_x, concat_segs({{pad, {}}}, picture_row(pic, row)))
				}
			case !here:
				append(&l.wants, Want{m.id, i, f.blob})
				add_row(l, .Files, m.id, text_x, {{pad, {}}, {"  loading the picture…", theme.dim}})
			}
		}
	}
	if len(m.reactions) > 0 && .Deleted not_in m.flags {
		segs := make([dynamic]Seg, context.temp_allocator)
		chips := make([dynamic]Chip, context.temp_allocator)
		append(&segs, Seg{pad, {}})
		x := text_x
		for r in m.reactions {
			text := fmt.aprintf(" %s %d ", r.emoji, r.count)
			w := tui.string_width(text)
			append(&segs, Seg{text, theme.reaction_me if r.me else theme.reaction})
			append(&chips, Chip{emoji = strings.clone(r.emoji), start = x, end = x + w, me = r.me})
			append(&segs, Seg{" ", {}})
			x += w + 1
		}
		add_row(l, .Reactions, m.id, text_x, segs[:])
		l.rows[len(l.rows) - 1].chips = slice_clone(chips[:])
	}
	if !in_thread && .Has_Thread in m.flags && m.reply_count > 0 {
		word := "reply" if m.reply_count == 1 else "replies"
		add_row(
			l,
			.Thread,
			m.id,
			text_x,
			{{pad, {}}, {fmt.aprintf("↩ %d %s", m.reply_count, word), theme.mention}},
		)
	}
}

// human_size writes a size in bytes the way people read it.
human_size :: proc(n: u64) -> string {
	switch {
	case n < 1024:
		return fmt.aprintf("%d B", n)
	case n < 1024 * 1024:
		return fmt.aprintf("%.1f KB", f64(n) / 1024)
	case n < 1024 * 1024 * 1024:
		return fmt.aprintf("%.1f MB", f64(n) / (1024 * 1024))
	}
	return fmt.aprintf("%.1f GB", f64(n) / (1024 * 1024 * 1024))
}

@(private = "file")
slice_clone :: proc(c: []Chip) -> []Chip {
	out := make([]Chip, len(c))
	copy(out, c)
	return out
}

// saves_signature is a number that changes when a file being saved changes state
// or moves on by a few percent, so the rows are laid out again then.
@(private = "file")
saves_signature :: proc(v: ^conn.View) -> (sig: u64) {
	for blob, sv in v.saves {
		sig += u64(blob) * 31 + u64(sv.state) * 1000003 + sv.done * 20 / max(sv.size, 1)
	}
	for p in v.outbox {
		for f in p.files {
			sig += f.done * 20 / max(f.size, 1) + 7
		}
	}
	return
}
