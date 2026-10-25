package client

import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:richtext"
import "common:proto"

// Searching messages (src/common/proto/search.odin) happens in a floating
// window opened by the magnifier in the conversation's header. It has a box to
// type in, a checkbox to look in all of our conversations instead of only this
// one, and the results, newest first. Each result has Go to (which jumps there
// like a link does, see ui_forward.odin), and More at the end loads older
// results.
//
// Words match whole words regardless of case and accents. "a phrase" matches
// the words in a row, and from:username matches one person's messages.

UI_Search :: struct {
	open:   bool,
	placed: bool,
	query:  Text_Field(proto.MAX_SEARCH_QUERY),
	all:    bool, // search in all of our conversations
}

@(private = "file")
SEARCH_WINDOW :: "Search"

// search_button is the header's magnifier, which opens and closes the window.
// Call with the View locked.
search_button :: proc(ui: ^UI) {
	s := &ui.search
	if .SUBMIT in
	   icon_button(
		   ui,
		   "search",
		   .Search,
		   "Close the search" if s.open else "Search messages",
		   theme.chat_name if s.open else {},
	   ) {
		s.open = !s.open
		s.placed = false
	}
}

search_window :: proc(ui: ^UI, window_w, window_h: i32) {
	s := &ui.search
	if !s.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.status != .Connected {
		s.open = false
		return
	}
	if !s.placed {
		s.placed = true
		w := clamp(window_w / 3, 280, 460)
		h := clamp(window_h - 120, 200, 640)
		if cnt := mu.get_container(ctx, SEARCH_WINDOW); cnt != nil {
			cnt.rect = {window_w - w - 20, 60, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, SEARCH_WINDOW, {}) {
		s.open = false
		return
	}
	defer mu.end_window(ctx)

	cmds := &ui.session.client.commands
	mu.layout_row(ctx, {-(70 + ctx.style.spacing + 1), 70})
	submit := .SUBMIT in text_box(ui, s.query.buf[:], &s.query.len)
	submit |= .SUBMIT in stable_button(ctx, "find", "Search", {.ALIGN_CENTER})
	mu.layout_row(ctx, {-1})
	if .CHANGE in checkbox(ctx, "In all my conversations", &s.all) && v.search.query != "" {
		submit = true
	}
	query := strings.trim_space(field_text(&s.query))
	if submit && query != "" {
		conn.push_command(cmds, conn.Search_Command{query = strings.clone(query), all = s.all})
	}

	found := &v.search
	mu.layout_row(ctx, {-1})
	switch {
	case found.error != "":
		with_text_color(ctx, theme.error, found.error, label_proc)
		return
	case found.query == "":
		with_text_color(ctx, theme.dim, `Whole words, "a phrase", from:username.`, label_proc)
		return
	case found.loading && len(found.found) == 0:
		with_text_color(ctx, theme.dim, "Searching...", label_proc)
		return
	case len(found.found) == 0 && !found.more:
		with_text_color(ctx, theme.dim, fmt.tprintf("Nothing has %q.", found.query), label_proc)
		return
	case len(found.found) == 0:
		// The search stopped because of its time limit before finding any
		// result, so older messages are left.
		with_text_color(ctx, theme.dim, "Nothing yet in the newest messages.", label_proc)
	}
	for f, i in found.found {
		m := f.msg
		mu.push_id(ctx, uintptr(m.id))
		defer mu.pop_id(ctx)
		name := "someone"
		if acc, ok := v.accounts[m.sender]; ok {
			name = acc.display
		}
		place := ""
		if found.conv == 0 {
			place = fmt.tprintf("  in %s", conversation_name(v, f.conv))
		}
		mu.layout_row(ctx, {-70, -1})
		with_text_color(
			ctx,
			author_color(v, m.sender),
			fmt.tprintf("%s  %s%s", chat_time(ui, proto.Unix_Time(m.time / 1000)), name, place),
			label_proc,
		)
		if .SUBMIT in stable_button(ctx, "go", "Go to") {
			go_to_message(ui, f.conv, m.id)
		}
		mu.layout_row(ctx, {-1})
		text, _, _ := richtext.text_display(m.text, v.accounts, v.roles[:], v.me, v.emoji.names[:])
		if text != "" {
			mu.text(ctx, richtext.markdown_plain(text))
		}
		// Its files, which may be what the message was found by.
		if len(m.files) > 0 {
			names := make([]string, len(m.files), context.temp_allocator)
			for f, j in m.files {
				names[j] = f.name
			}
			mu.layout_row(ctx, {-1})
			with_text_color(
				ctx,
				theme.dim,
				fmt.tprintf("files: %s", strings.join(names, ", ", context.temp_allocator)),
				mu.text,
			)
		}
		if i < len(found.found) - 1 {
			mu.layout_row(ctx, {-1}, 1)
			mu.draw_rect(ctx, mu.layout_next(ctx), theme.divider)
		}
	}
	if found.loading {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "Searching...", label_proc)
	} else if found.more {
		mu.layout_row(ctx, {140})
		if .SUBMIT in
		   stable_button(
			   ctx,
			   "more",
			   "Search further" if len(found.found) == 0 else "More...",
			   {.ALIGN_CENTER},
		   ) {
			conn.push_command(cmds, conn.Search_Command{more = true})
		}
	}
}

// conversation_name is how a list names one of our conversations: #name, or
// the other person's name for a DM. Call with the View locked.
conversation_name :: proc(v: ^conn.View, conv: proto.Conv_Id) -> string {
	for ch in v.channels {
		if ch.id == conv {
			return fmt.tprintf("#%s", ch.name)
		}
	}
	for dm in v.dms {
		if dm.id == conv {
			if acc, ok := v.accounts[dm.with]; ok {
				return acc.display
			}
		}
	}
	return "a conversation"
}
