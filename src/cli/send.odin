package main

import "core:strings"

import "client:conn"
import "common:proto"
import "client:richtext"
import "tui"

// What the message box does with what is written in it.

// submit sends the message box's text: as a command if it starts with "/", else
// as a message (a reply, or the new text of a message being edited).
submit :: proc(a: ^App) {
	text := strings.trim_space(tui.editor_text(&a.editor))
	if text == "" {
		return
	}
	if strings.has_prefix(text, "/") && !strings.has_prefix(text, "//") {
		tui.editor_remember(&a.editor)
		run_command(a, text)
		return
	}
	// "//" writes a slash.
	text = text[1:] if strings.has_prefix(text, "//") else text
	switch {
	case a.editing != 0:
		push(a, conn.Edit_Command{id = a.editing, text = strings.clone(text), typed = true})
		cancel_edit(a)
	case a.viewing == 0:
		say(a, "Pick a channel first.", true)
		return
	case a.reply_to != 0 || a.thread != 0:
		root := a.reply_to if a.reply_to != 0 else a.thread
		push(
			a,
			conn.Chat_Command {
				text = strings.clone(text),
				thread = {a.viewing, root},
				typed = true,
			},
		)
		cancel_reply(a)
	case:
		push(a, conn.Chat_Command{text = strings.clone(text), typed = true})
	}
	tui.editor_remember(&a.editor)
	a.scroll = 0
}

cancel_reply :: proc(a: ^App) {
	a.reply_to = 0
	delete(a.reply_name)
	a.reply_name = ""
}

cancel_edit :: proc(a: ^App) {
	if a.editing != 0 {
		a.editing = 0
		tui.editor_clear(&a.editor)
	}
}

// start_reply makes the message box post in the thread of a message. Call with
// the View locked.
start_reply :: proc(a: ^App, m: conn.View_Message) {
	cancel_edit(a)
	cancel_reply(a)
	// A reply to a reply goes to the thread of its root.
	a.reply_to = m.thread_root if m.thread_root != 0 else m.id
	a.reply_name = strings.clone(sender_name(a.view, m))
	a.focus = .Composer
}

// start_edit puts a message of ours in the message box to be changed. Call with
// the View locked.
start_edit :: proc(a: ^App, m: conn.View_Message) {
	cancel_reply(a)
	a.editing = m.id
	tui.editor_set(&a.editor, richtext.mentions_for_edit(m.text, a.view.accounts, a.view.roles[:]))
	a.focus = .Composer
}

// last_own_message is the newest message of ours that can be edited. Call with
// the View locked.
last_own_message :: proc(a: ^App) -> (m: conn.View_Message, ok: bool) {
	tl, have := &a.view.timelines[{a.view.viewing, 0}]
	if !have {
		return
	}
	#reverse for msg in tl.messages {
		if can_edit(a.view, msg) {
			return msg, true
		}
	}
	return
}

// copy_text asks for text to be put on the clipboard.
copy_text :: proc(a: ^App, text: string) {
	delete(a.clipboard)
	a.clipboard = strings.clone(text)
	say(a, "Copied.")
}


// open_thread shows a thread beside the messages (or over them) and writes to it.
// Opening another closes the first. Call with the View locked.
open_thread :: proc(a: ^App, root: proto.Msg_Id) {
	if a.thread == root || a.viewing == 0 {
		return
	}
	close_thread(a)
	a.thread, a.thread_scroll, a.thread_asked = root, 0, 0
	push(a, conn.Thread_Command{thread = {a.viewing, root}, open = true})
}

close_thread :: proc(a: ^App) {
	if a.thread != 0 {
		push(a, conn.Thread_Command{thread = {a.viewing, a.thread}, open = false})
		a.thread, a.thread_scroll, a.thread_asked = 0, 0, 0
		layout_destroy(&a.thread_layout)
		a.members_asked = 0
	}
}

// thread_root_of is the root of the thread a message belongs to or starts.
thread_root_of :: proc(m: conn.View_Message) -> proto.Msg_Id {
	return m.thread_root if m.thread_root != 0 else m.id
}
