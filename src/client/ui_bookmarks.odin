package client

import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:richtext"
import "common:proto"

// Bookmarks (src/common/proto/bookmarks.odin): messages we marked to come back
// to, in a list that only we see. A message is bookmarked from its menu
// (ui_message_menu.odin), and its header then says so. The list is a floating
// window, opened and closed by the Bookmarks row at the top of the channel
// list, with the newest bookmark first. Each entry says who wrote the message
// and when, what it says, and where it is, with Go to (which jumps there like a search result
// does) and Remove; More at the end loads older ones. The window stays open
// while jumping, so that one can go through the list.
//
// The network side fetches the list when the window opens, and again while
// it is open whenever a bookmark comes or goes.

UI_Bookmarks :: struct {
	open:   bool,
	placed: bool, // whether its position has been set since it was opened
	asked:  bool, // whether the list was asked for since it was opened
}

@(private = "file")
BOOKMARKS_WINDOW :: "Bookmarks"

// BOOKMARKS_NAME is what the row in the channel list says.
BOOKMARKS_NAME :: "Bookmarks"

// toggle_bookmarks opens the window, or closes it.
toggle_bookmarks :: proc(ui: ^UI) {
	b := &ui.bookmarks
	b.open = !b.open
	b.placed, b.asked = false, false
	if !b.open && ui.session != nil {
		conn.push_command(&ui.session.client.commands, conn.Bookmarks_Command{close = true})
	}
}

bookmarks_window :: proc(ui: ^UI, window_w, window_h: i32) {
	b := &ui.bookmarks
	if !b.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.status != .Connected {
		b.open = false
		return
	}
	cmds := &ui.session.client.commands
	if !b.asked {
		b.asked = true
		conn.push_command(cmds, conn.Bookmarks_Command{})
	}
	if !b.placed {
		b.placed = true
		w := clamp(window_w / 3, 260, 420)
		h := clamp(window_h - 120, 200, 600)
		if cnt := mu.get_container(ctx, BOOKMARKS_WINDOW); cnt != nil {
			cnt.rect = {window_w - w - 20, 60, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, BOOKMARKS_WINDOW, {}) {
		// Closed with the title bar's button.
		b.open = false
		conn.push_command(cmds, conn.Bookmarks_Command{close = true})
		return
	}
	keep_in_window(ui) // dragged: kept below the top bar, on screen
	defer mu.end_window(ctx)

	bm := &v.bookmarks
	if !bm.listed {
		spinner_row(ui)
		return
	}
	if len(bm.list) == 0 {
		mu.layout_row(ctx, {-1})
		dim_label(
			ctx,
			"Nothing is bookmarked yet. Bookmark a message from its menu (right-click it).",
		)
		return
	}
	for e, i in bm.list {
		m := e.msg
		mu.push_id(ctx, uintptr(m.id))
		defer mu.pop_id(ctx)
		name := "someone"
		if acc, ok := v.accounts[m.sender]; ok {
			name = acc.display
		}
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			author_color(v, m.sender),
			fmt.tprintf("%s  %s", chat_time(ui, proto.Unix_Time(m.time / 1000)), name),
			label_proc,
		)
		mu.layout_row(ctx, {-1})
		bookmark_text(ui, m)
		mu.layout_row(ctx, {-150, 70, -1})
		with_text_color(ctx, theme.dim, bookmark_place(v, e.conv, m), label_proc)
		if .SUBMIT in stable_button(ctx, "go", "Go to") {
			go_to_message(ui, e.conv, m.id)
			ui.channels.show_list = false
		}
		if .SUBMIT in stable_button(ctx, "remove", "Remove") {
			conn.push_command(cmds, conn.Bookmark_Command{id = m.id})
		}
		if i < len(bm.list) - 1 {
			mu.layout_row(ctx, {-1}, 1)
			mu.draw_rect(ctx, mu.layout_next(ctx), theme.divider)
		}
	}
	if bm.loading {
		spinner_row(ui)
	} else if bm.more {
		mu.layout_row(ctx, {140})
		if .SUBMIT in stable_button(ctx, "more", "More...", {.ALIGN_CENTER}) {
			conn.push_command(cmds, conn.Bookmarks_Command{more = true})
		}
	}
}

// bookmark_place says where a bookmarked message is: "in #channel", "with
// Bob" for a DM or a group, and whether it is a reply in a thread there.
@(private = "file")
bookmark_place :: proc(v: ^conn.View, conv: proto.Conv_Id, m: conn.View_Message) -> string {
	name := conversation_name(v, conv)
	place :=
		fmt.tprintf("in %s", name) if strings.has_prefix(name, "#") else fmt.tprintf("with %s", name)
	if m.thread_root != 0 {
		return fmt.tprintf("a reply %s", place)
	}
	return place
}

// bookmark_text is what a bookmarked message says, on as many lines as it
// takes.
@(private = "file")
bookmark_text :: proc(ui: ^UI, m: conn.View_Message) {
	ctx := &ui.ctx
	v := ui.view
	if .Deleted in m.flags {
		dim_label(ctx, "This message was deleted.")
		return
	}
	text: string
	switch m.kind {
	case .Text:
		text, _, _ = richtext.text_display(m.text, v.accounts, v.roles[:], v.me, v.emoji.names[:])
		text = richtext.markdown_plain(text)
	case .File:
		text = fmt.tprintf("the file %s", m.text)
	case .System:
		text = "a note about the conversation"
	}
	if text != "" {
		wrap_text(ctx, text)
	}
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
			wrap_text,
		)
	}
}
