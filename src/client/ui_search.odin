package client

import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:richtext"
import "common:proto"

// Searching messages (src/common/proto/search.odin). Beside a channel whose
// members are pinned down the side, it is a box above them (search_box):
// giving it the focus opens a dropdown under it, as wide as the box, with a
// checkbox to look in all of our conversations instead of only this one, and
// the results, newest first. A click outside the box and the dropdown, or
// Escape, closes it again. Elsewhere (a DM, or a window too narrow for the
// members) a magnifier in the conversation's header opens the same in a
// floating window, with the box at its top. Each result has Go to (which
// jumps there like a link does, see ui_forward.odin), and More at the end
// loads older results.
//
// Words match whole words regardless of case and accents. "a phrase" matches
// the words in a row, from:username matches one person's messages, and
// has:file only messages with files. The file button beside the pins searches
// for has:file alone: every message with files in the conversation
// (files_button).

UI_Search :: struct {
	open:     bool,
	placed:   bool,
	focus:    bool, // just opened: the query box takes the focus
	query:    Text_Field(proto.MAX_SEARCH_QUERY),
	all:      bool, // search in all of our conversations
	// Where search_box put the box in this frame, or {} if it isn't there and
	// the search is the floating window. Whether it was there last frame.
	box:      mu.Rect,
	dropdown: bool,
	submit:   bool, // Enter in search_box, for the dropdown to search
}

@(private = "file")
SEARCH_WINDOW :: "Search"
@(private = "file")
SEARCH_DROPDOWN :: "search dropdown"
@(private = "file")
DROPDOWN_PAD :: 6

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

// files_button is the header's sheets of paper, which search the conversation
// for every message with files.
files_button :: proc(ui: ^UI) {
	if .SUBMIT in icon_button(ui, "files", .File, "Messages with files") {
		search_for(ui, "has:file")
	}
}

// search_for opens the search (the box's dropdown or the window) and searches
// this conversation for `query`.
search_for :: proc(ui: ^UI, query: string) {
	s := &ui.search
	field_set(&s.query, query)
	s.all = false
	s.open, s.placed, s.submit = true, false, true
}

// search_box is the box above the members pinned down the side, in a row of
// its own. Giving it the focus opens the dropdown (search_window). Call with the
// View locked.
search_box :: proc(ui: ^UI) {
	ctx := &ui.ctx
	s := &ui.search
	// As much room around it as the conversation's header has.
	header_pad(ui)
	defer header_pad(ui)
	mu.layout_row(ctx, {-1})
	id := mu.get_id(ctx, uintptr(&s.query.buf[0]))
	// Opened from elsewhere (the palette): ready to type in. Not in the frame
	// of a click, which would take the focus from the box again.
	if s.open && !s.placed && ctx.mouse_pressed_bits == {} {
		s.placed = true
		focus_at(ctx, id, s.query.len)
	}
	if .SUBMIT in text_box(ui, s.query.buf[:], &s.query.len) {
		s.submit = true
	}
	r := ctx.last_rect
	s.box = r
	if ctx.focus_id == id && !s.open {
		s.open, s.placed = true, true
	}
	// What it is for while it is empty, and a magnifier at its end.
	pad := ctx.style.padding
	if s.query.len == 0 && ctx.focus_id != id {
		y := r.y + (r.h - ctx.text_height(ctx.style.font)) / 2
		mu.draw_text(ctx, ctx.style.font, "Search messages", {r.x + pad, y}, theme.dim)
	}
	mu.draw_icon(ctx, render.icon_id(.Search), {r.x + r.w - r.h, r.y, r.h, r.h}, theme.dim)
}

search_window :: proc(ui: ^UI, window_w, window_h: i32) {
	s := &ui.search
	box := s.box
	s.box = {}
	submit := s.submit
	s.submit = false
	// From the box to the window or back (the members were pinned or let go):
	// whatever was open closes.
	if (box != {}) != s.dropdown {
		s.dropdown = box != {}
		s.open = false
	}
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
	if box != {} {
		search_dropdown(ui, box, window_h, submit)
		return
	}
	if !s.placed {
		s.placed = true
		s.focus = true
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
	keep_in_window(ui) // dragged: kept below the top bar, on screen
	defer mu.end_window(ctx)

	// Ready to type in, however it was opened. Not in the frame of the click
	// that opened it, which would take the focus from the box again.
	if s.focus && ctx.mouse_pressed_bits == {} {
		s.focus = false
		focus_at(ctx, mu.get_id(ctx, uintptr(&s.query.buf[0])), s.query.len)
	}
	mu.layout_row(ctx, {-(70 + ctx.style.spacing + 1), 70})
	find := .SUBMIT in text_box(ui, s.query.buf[:], &s.query.len)
	find |= submit
	find |= .SUBMIT in stable_button(ctx, "find", "Search", {.ALIGN_CENTER})
	search_results(ui, find)
}

// search_dropdown is the dropdown under search_box's `box`: a window without a
// title, as wide as the box and as tall as what is in it, up to the bottom of
// the window. A press anywhere but in it or the box closes it, and so does
// Escape. Call with the View locked.
@(private = "file")
search_dropdown :: proc(ui: ^UI, box: mu.Rect, window_h: i32, submit: bool) {
	ctx := &ui.ctx
	s := &ui.search
	cnt := mu.get_container(ctx, SEARCH_DROPDOWN)
	if cnt == nil {
		return
	}
	if key_take(ui, .Escape) {
		s.open = false
		mu.set_focus(ctx, 0) // which would open it again
		return
	}
	// Not the press that opened it from elsewhere (search_for), before the
	// box has the focus.
	if ctx.mouse_pressed_bits != {} &&
	   s.placed &&
	   !inside(box, ctx.mouse_pos) &&
	   !(cnt.open && inside(cnt.rect, ctx.mouse_pos)) {
		s.open = false
		return
	}
	top := box.y + box.h + 2
	most := max(window_h - top - 12, 60)
	if !cnt.open {
		cnt.open = true
		cnt.scroll = {}
		cnt.content_size = {}
		mu.bring_to_front(ctx, cnt)
	}
	// More room inside than a window has.
	pad := ctx.style.padding + DROPDOWN_PAD
	h := clamp(cnt.content_size.y + 2 * pad, 40, most)
	cnt.rect = {box.x, top, box.w, h}
	opts := mu.Options{.NO_TITLE, .NO_RESIZE, .NO_CLOSE}
	saved := ctx.style.padding
	ctx.style.padding = pad // the window's body is inset by it
	opened := mu.begin_window(ctx, SEARCH_DROPDOWN, cnt.rect, opts)
	ctx.style.padding = saved
	if !opened {
		return
	}
	defer mu.end_window(ctx)
	search_results(ui, submit)
	// Shut with the search, so that it opens afresh next time.
	defer if !s.open {
		cnt.open = false
	}
}

// search_results is what is under the query box: whether to look in all of our
// conversations, and the results. With `submit`, the query is searched for.
// Call with the View locked.
@(private = "file")
search_results :: proc(ui: ^UI, submit: bool) {
	ctx := &ui.ctx
	s := &ui.search
	v := ui.view
	submit := submit
	cmds := &ui.session.client.commands
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
		error_label(ctx, found.error)
		return
	case found.query == "":
		dim_label(ctx, `Whole words, "a phrase", from:username, has:file.`)
		return
	case found.loading && len(found.found) == 0:
		dim_label(ctx, "Searching...")
		return
	case len(found.found) == 0 && !found.more:
		dim_label(ctx, fmt.tprintf("Nothing has %q.", found.query))
		return
	case len(found.found) == 0:
		// The search stopped because of its time limit before finding any
		// result, so older messages are left.
		dim_label(ctx, "Nothing yet in the newest messages.")
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
		dim_label(ctx, "Searching...")
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
// the other person's name for a DM, or the others' for a group. Call with the
// View locked.
conversation_name :: proc(v: ^conn.View, conv: proto.Conv_Id) -> string {
	for ch in v.channels {
		if ch.id == conv {
			return fmt.tprintf("#%s", ch.name)
		}
	}
	for &dm in v.dms {
		if dm.id == conv {
			return dm_name(v, &dm)
		}
	}
	return "a conversation"
}
