package main

import "core:fmt"
import "core:strings"
import "core:time"

import "client:conn"
import "tui"

// The right-hand side: the title bar, the messages, the info line, the message
// box and, below everything, the status bar.

draw_chat :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	draw_title(a, b, g.title)
	if !g.thread_over {
		draw_rows(a, b, g.timeline, &a.layout, a.scroll)
	}
	draw_thread(a, b, g)
	draw_info(a, b, g.info)
	draw_composer(a, b, g.composer)
}

@(private = "file")
draw_title :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect) {
	v := a.view
	tui.fill(b, r, theme.bar)
	bold := tui.Style{fg = theme.bar.fg, bg = theme.bar.bg, attrs = {.Bold}}
	dim := tui.Style{fg = theme.dim.fg, bg = theme.bar.bg}
	x := r.x + 1
	if ch := conn.viewed_channel(v); ch != nil {
		x = tui.put_string(b, x, r.y, "# ", dim, r.x + r.w)
		x = tui.put_string(b, x, r.y, ch.name, bold, r.x + r.w)
		if ch.topic != "" {
			tui.put_string(b, x + 2, r.y, tui.cut_to_width(one_line(ch.topic), max(r.w - (x - r.x) - 4, 0)), dim, r.x + r.w)
		}
	} else if dm := viewed_dm(v); dm != nil {
		mark := "◆ " if dm.count > 0 else "@ "
		x = tui.put_string(b, x, r.y, mark, dim, r.x + r.w)
		tui.put_string(b, x, r.y, conn.dm_name(v, dm), bold, r.x + r.w)
	} else if v.viewing == 0 {
		tui.put_string(b, x, r.y, "no conversation", dim, r.x + r.w)
	}
	// Something is wrong with the connection.
	if v.status != .Connected {
		text := connection_text(v)
		w := tui.string_width(text)
		tui.put_string(b, r.x + r.w - w - 1, r.y, text, {fg = theme.error.fg, bg = theme.bar.bg}, r.x + r.w)
	}
}

@(private = "file")
one_line :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	return out
}

// connection_text says how the connection is, when it isn't up.
connection_text :: proc(v: ^conn.View) -> string {
	switch v.status {
	case .Disconnected: return "disconnected"
	case .Connecting: return "connecting..."
	case .Failed: return fmt.tprintf("%s%s", v.error, " (trying again)" if v.retrying else "")
	case .Connected: return ""
	}
	return ""
}

// draw_rows draws laid out rows into a region, the newest at the bottom, with
// the rows' places to click.
draw_rows :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect, layout: ^Timeline_Layout, scroll: int) {
	rows := layout.rows
	if r.h <= 0 || r.w <= 0 {
		return
	}
	// The newest row is at the bottom; `scroll` rows of newer ones are out of sight.
	end := len(rows) - scroll
	first := end - r.h
	text_w := r.w - 1 // the scroll bar
	for y in 0 ..< r.h {
		i := first + y
		if i < 0 || i >= end {
			continue
		}
		row := rows[i]
		picked := row.msg != 0 && row.msg == a.cursor_msg
		if picked {
			tui.fill(b, {r.x, r.y + y, text_w, 1}, theme.selected)
		}
		x := r.x
		for s in row.segs {
			style := s.style
			if picked {
				style.bg = theme.selected.bg
			}
			x = tui.put_string(b, x, r.y + y, s.text, style, r.x + text_w)
		}
		if row.msg != 0 {
			kind := Hit_Kind.Thread if row.kind == .Thread else Hit_Kind.Message
			append(&a.hits, Hit{{r.x, r.y + y, text_w, 1}, kind, u64(row.msg), ""})
			// Each reaction can be clicked on its own, over the message.
			for chip in row.chips {
				append(&a.hits, Hit{{r.x + chip.start, r.y + y, chip.end - chip.start, 1}, .Reaction, u64(row.msg), chip.emoji})
			}
		}
	}
	draw_scrollbar(b, {r.x + r.w - 1, r.y, 1, r.h}, len(rows), r.h, scroll)
}

@(private = "file")
draw_thread :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	r := g.thread
	if r.w == 0 {
		return
	}
	tui.fill(b, r, {})
	if !g.thread_over {
		for y in 0 ..< g.thread_border.h {
			tui.set_cell(b, g.thread_border.x, y, '│', 1, theme.border)
		}
	}
	tui.fill(b, {r.x, r.y, r.w, 1}, theme.bar)
	tui.put_string(b, r.x + 1, r.y, "Thread", {fg = theme.bar.fg, bg = theme.bar.bg, attrs = {.Bold}}, r.x + r.w)
	close := " ✕ close "
	cx := r.x + r.w - tui.string_width(close)
	tui.put_string(b, cx, r.y, close, theme.bar, r.x + r.w)
	append(&a.hits, Hit{{cx, r.y, tui.string_width(close), 1}, .Close_Thread, 0, ""})
	draw_rows(a, b, {r.x, r.y + 1, r.w, r.h - 1}, &a.thread_layout, a.thread_scroll)
}

// draw_scrollbar draws a thumb for the part of `total` rows that is in view, `scroll`
// rows from the end.
draw_scrollbar :: proc(b: ^tui.Buffer, r: tui.Rect, total, visible, scroll: int) {
	if total <= visible || r.h <= 0 {
		return
	}
	thumb := max(r.h * visible / total, 1)
	top := (r.h - thumb) * (total - visible - scroll) / (total - visible)
	for y in 0 ..< r.h {
		in_thumb := y >= top && y < top + thumb
		tui.set_cell(b, r.x, r.y + y, '█' if in_thumb else '│', 1, theme.dim if in_thumb else theme.border)
	}
}

@(private = "file")
draw_info :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect) {
	v := a.view
	x := r.x + 1
	max_x := r.x + r.w
	switch {
	case a.editing != 0:
		tui.put_string(b, x, r.y, "✎ Editing your message (Esc to cancel)", theme.mention, max_x)
	case a.thread != 0 && a.reply_to == 0:
		tui.put_string(b, x, r.y, "↪ Writing in the thread (Esc closes it)", theme.mention, max_x)
	case a.reply_to != 0:
		text := fmt.tprintf("↪ Replying to %s (Esc to cancel)", a.reply_name)
		tui.put_string(b, x, r.y, text, theme.mention, max_x)
	case len(a.attached) > 0:
		text := fmt.tprintf("📎 %d file(s) will go with the next message (/unattach removes them)", len(a.attached))
		tui.put_string(b, x, r.y, text, theme.mention, max_x)
	case incoming_call_text(v) != "":
		tui.put_string(b, x, r.y, incoming_call_text(v), theme.mention_me, max_x)
	case a.notice != "":
		tui.put_string(b, x, r.y, a.notice, theme.error if a.notice_error else theme.dim, max_x)
	case a.scroll > 0:
		tui.put_string(b, x, r.y, "↓ older messages — PgDn or End for the newest", theme.dim, max_x)
	case:
		if text := typing_text(v); text != "" {
			tui.put_string(b, x, r.y, text, theme.dim, max_x)
		}
	}
}

// typing_text says who is typing in the conversation shown.
typing_text :: proc(v: ^conn.View) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for id, t in v.typing {
		if id == v.me || t.to != (conn.Timeline_Key{v.viewing, 0}) || time.tick_since(t.at) > conn.TYPING_SHOW {
			continue
		}
		if acc, ok := v.accounts[id]; ok {
			append(&names, acc.display)
		}
	}
	switch len(names) {
	case 0: return ""
	case 1: return fmt.tprintf("%s is typing…", names[0])
	case 2: return fmt.tprintf("%s and %s are typing…", names[0], names[1])
	}
	return "several people are typing…"
}

@(private = "file")
draw_composer :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect) {
	prompt := "> "
	text_x := r.x + len(prompt)
	text_w := r.w - len(prompt)
	append(&a.hits, Hit{r, .Composer, 0, ""})
	text := tui.editor_text(&a.editor)
	lines := make([dynamic]tui.Line, context.temp_allocator)
	cx, cy := tui.editor_layout(&a.editor, max(text_w, 1), &lines)
	// Show the lines that have the cursor if there are more than fit.
	top := max(cy - r.h + 1, 0)
	if text == "" {
		tui.put_string(b, r.x, r.y, prompt, theme.dim, r.x + r.w)
		hint := "Message — / for commands, F1 for help"
		tui.put_string(b, text_x, r.y, hint, theme.dim, r.x + r.w)
	}
	for y in 0 ..< r.h {
		i := top + y
		if i >= len(lines) {
			break
		}
		if text != "" {
			tui.put_string(b, r.x, r.y + y, prompt if i == 0 else "  ", theme.dim, r.x + r.w)
			tui.put_string(b, text_x, r.y + y, text[lines[i].start:lines[i].end], {}, r.x + r.w)
		}
	}
	if a.focus == .Composer && a.dialog.kind == .None {
		a.cursor = {text_x + cx, r.y + cy - top}
		a.cursor_shown = true
	}
}

draw_status :: proc(a: ^App, b: ^tui.Buffer, g: Geometry) {
	r := g.status
	v := a.view
	tui.fill(b, r, theme.bar)
	left := fmt.tprintf(" %s", v.my_name if v.my_name != "" else "not logged in")
	x := tui.put_string(b, r.x, r.y, left, theme.bar, r.x + r.w)
	if text, style := voice_status(a); text != "" {
		x = tui.put_string(b, x + 2, r.y, text, style, r.x + r.w)
	}
	if v.status != .Connected {
		tui.put_string(b, x + 2, r.y, connection_text(v), {fg = theme.error.fg, bg = theme.bar.bg}, r.x + r.w)
	}
	// Unread elsewhere, at the right.
	elsewhere, mentions := 0, 0
	for row in list_rows(v) {
		if row.kind != .Header && row.conv != v.viewing {
			elsewhere += row.unread
			mentions += row.mentions
		}
	}
	right := "F5 mute  F1 help" if in_voice(v) else "F1 help"
	if elsewhere > 0 {
		right = fmt.tprintf("%d unread%s   F1 help", elsewhere, fmt.tprintf(" (%d @)", mentions) if mentions > 0 else "")
	}
	tui.put_string(b, r.x + r.w - tui.string_width(right) - 1, r.y, right, theme.bar, r.x + r.w)
}

// owned_by_me says whether a message is ours.
owned_by_me :: proc(v: ^conn.View, m: conn.View_Message) -> bool {
	return m.sender == v.me && m.kind != .System
}

// can_edit and can_delete say what we may do to a message, as the channel's
// rights and the server's permissions allow. Call with the View locked.
can_edit :: proc(v: ^conn.View, m: conn.View_Message) -> bool {
	ch := conn.viewed_channel(v)
	return owned_by_me(v, m) && .Deleted not_in m.flags && m.kind == .Text && (ch == nil || .Edit in ch.rights)
}

can_delete :: proc(v: ^conn.View, m: conn.View_Message) -> bool {
	ch := conn.viewed_channel(v)
	if .Deleted in m.flags || m.kind == .System {
		return false
	}
	if owned_by_me(v, m) {
		return ch == nil || .Delete in ch.rights
	}
	return .Manage_Messages in v.permissions
}

can_react :: proc(v: ^conn.View) -> bool {
	if dm := viewed_dm(v); dm != nil {
		return !conn.dm_closed(v, dm)
	}
	ch := conn.viewed_channel(v)
	return ch == nil || .React in ch.rights
}

can_write :: proc(v: ^conn.View) -> bool {
	if dm := viewed_dm(v); dm != nil {
		return !conn.dm_closed(v, dm)
	}
	ch := conn.viewed_channel(v)
	return ch == nil || .Write in ch.rights
}

// viewed_dm is the DM or group being looked at, or nil. Call with the View locked.
viewed_dm :: proc(v: ^conn.View) -> ^conn.View_DM {
	for &dm in v.dms {
		if dm.id == v.viewing {
			return &dm
		}
	}
	return nil
}

