package client

import log "common:wlog"
import "core:strings"
import mu "vendor:microui"

import "common:proto"
import "client:conn"

/*
A message's own menu, opened by right-clicking it in a timeline: copy
its text, save its picture, react to it, reply in its thread, edit it,
pin or unpin it, delete it. Each is offered only where it's allowed (the
server checks again):

	Reply in thread   in the conversation's timeline (a thread's window
	                  has its composer already)
	Edit     our own text messages
	Delete   our own, or anyone's with Manage_Messages; asked twice
	Pin      either of the two in a DM, Pin_Messages in a channel; not a
	         reply in a thread
*/

UI_Message_Menu :: struct {
	requested: bool, // open it this frame
	id:        proto.Msg_Id,
	conv:      proto.Conv_Id,
	sender:    proto.Account_Id,
	kind:      proto.Msg_Kind,
	flags:     proto.Msg_Flags,
	root:      proto.Msg_Id, // a reply's thread
	// The timeline it was opened in: 0 the conversation's, else a
	// thread window's (UI_Timeline.slot).
	slot:      int,
	text:      string, // owned
	blob:      proto.Blob_Id,
	// Delete was pressed once: the menu asks whether to.
	confirm:   bool,
}

@(private = "file")
MENU :: "message menu"
@(private = "file")
MENU_WIDTH :: 180

// open_message_menu opens the menu for a message shown in a timeline.
// Call with the View locked.
open_message_menu :: proc(ui: ^UI, m: conn.View_Message, slot: int) {
	mm := &ui.msg_menu
	delete(mm.text)
	mm^ = {
		requested = true,
		id        = m.id,
		conv      = ui.view.viewing,
		sender    = m.sender,
		kind      = m.kind,
		flags     = m.flags,
		root      = m.thread_root,
		slot      = slot,
		text      = strings.clone(m.text),
		blob      = m.image.blob,
	}
}

ui_message_menu_destroy :: proc(ui: ^UI) {
	delete(ui.msg_menu.text)
	ui.msg_menu = {}
}

// may_pin_here is whether we may pin and unpin in the conversation
// being looked at. Call with the View locked.
may_pin_here :: proc(v: ^conn.View) -> bool {
	for dm in v.dms {
		if dm.id == v.viewing {
			return true
		}
	}
	return .Pin_Messages in v.permissions
}

/*
message_menu shows the menu while it's open, and does what's picked.
Call with the View locked, where user_menu is called.
*/
message_menu :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	mm := &ui.msg_menu
	if mm.requested {
		mm.requested = false
		mu.open_popup(ctx, MENU)
	}
	if cnt := mu.get_container(ctx, MENU, {.CLOSED}); cnt != nil && cnt.open {
		w, h := i32(ui.metrics.logical_w), i32(ui.metrics.logical_h)
		cnt.rect.x = clamp(cnt.rect.x, 0, max(w - cnt.rect.w, 0))
		cnt.rect.y = clamp(cnt.rect.y, 0, max(h - cnt.rect.h, 0))
	}
	if !mu.begin_popup(ctx, MENU) {
		mm.confirm = false
		return
	}
	defer mu.end_popup(ctx)

	// Gone from under the menu (another conversation is shown now).
	if mm.conv != v.viewing || ui.session == nil {
		mu.get_current_container(ctx).open = false
		return
	}
	cmds := &ui.session.client.commands
	deleted := .Deleted in mm.flags
	mine := mm.sender == v.me
	close :: proc(ctx: ^mu.Context) {
		mu.get_current_container(ctx).open = false
	}

	mu.layout_row(ctx, {MENU_WIDTH})
	if mm.confirm {
		with_text_color(ctx, DIM_COLOR, "Delete it for everyone?", label_proc)
		half := (MENU_WIDTH - ctx.style.spacing) / 2
		mu.layout_row(ctx, {half, half})
		if .SUBMIT in stable_button(ctx, "cancel", "Cancel") {
			mm.confirm = false
		}
		if .SUBMIT in stable_button(ctx, "delete", "Delete") {
			conn.push_command(cmds, conn.Delete_Command{id = mm.id})
			log.debug("ui: delete a message")
			mm.confirm = false
			close(ctx)
		}
		return
	}
	if deleted {
		with_text_color(ctx, DIM_COLOR, "This message was deleted.", label_proc)
		return
	}
	if mm.kind == .Text && .SUBMIT in stable_button(ctx, "copy", "Copy text") {
		shown, _ := conn.mentions_display(mm.text, v.accounts, v.me)
		set_clipboard(nil, shown)
		close(ctx)
	}
	if mm.kind == .Image {
		img, have := v.blobs[mm.blob]
		if have && img.state == .Ready && .SUBMIT in stable_button(ctx, "save", "Save picture") {
			request_save(&ui.images, img.jpeg)
			close(ctx)
		}
	}
	if .SUBMIT in stable_button(ctx, "react", "React...") {
		open_picker(ui, mm.id)
		close(ctx)
	}
	// A copy elsewhere, or a link to it (ui_forward.odin).
	if (mm.kind == .Text || (mm.kind == .Image && mm.blob != 0)) &&
	   .SUBMIT in stable_button(ctx, "forward", "Forward...") {
		open_forward(ui, mm.id)
		close(ctx)
	}
	if .SUBMIT in stable_button(ctx, "link", "Copy link") {
		set_clipboard(nil, proto.link_token(mm.conv, mm.id))
		close(ctx)
	}
	if mm.slot == 0 && .SUBMIT in stable_button(ctx, "reply", "Reply in thread") {
		open_thread(ui, {mm.conv, mm.root if mm.root != 0 else mm.id})
		close(ctx)
	}
	if mine && mm.kind == .Text && .Forwarded not_in mm.flags && .SUBMIT in stable_button(ctx, "edit", "Edit") {
		start_editing(ui, mm.id, mm.text, composer_of(ui, mm.slot))
		close(ctx)
	}
	if may_pin_here(v) && mm.root == 0 {
		pinned := .Pinned in mm.flags
		if .SUBMIT in stable_button(ctx, "pin", "Unpin" if pinned else "Pin") {
			conn.push_command(cmds, conn.Pin_Command{id = mm.id, on = !pinned})
			close(ctx)
		}
	}
	if (mine || .Manage_Messages in v.permissions) && .SUBMIT in stable_button(ctx, "delete?", "Delete...") {
		mm.confirm = true
	}
}

// start_editing loads one of our messages into a composer, to be edited
// there.
start_editing :: proc(ui: ^UI, id: proto.Msg_Id, text: string, c: Composer) {
	c.len^ = copy(c.buf, conn.mentions_for_edit(text, ui.view.accounts))
	c.editing^ = id
	c.conv^ = ui.view.viewing
	focus_composer(ui, c, -1)
}

// focus_composer has a composer take the focus when it's next laid
// out, with the cursor `at` (-1: the end).
focus_composer :: proc(ui: ^UI, c: Composer, at: int) {
	ui.focus_composer = true
	ui.focus_thread = c.thread
	ui.focus_composer_at = at
}

// takes_focus is whether a composer is to take the focus now (and it's
// taken).
takes_focus :: proc(ui: ^UI, c: Composer) -> bool {
	if !ui.focus_composer || ui.focus_thread != c.thread {
		return false
	}
	ui.focus_composer = false
	return true
}

// newest_own_text is the newest message of ours that can be edited in
// the conversation being looked at (or the thread), as far as its
// window goes. Call with the View locked.
newest_own_text :: proc(v: ^conn.View, key: conn.Timeline_Key) -> (conn.View_Message, bool) {
	tl, ok := v.timelines[key]
	if !ok {
		return {}, false
	}
	#reverse for m in tl.messages {
		if m.sender == v.me && m.kind == .Text && .Deleted not_in m.flags {
			return m, true
		}
	}
	return {}, false
}

// A composer's text and what it's editing: the chat's or the buddy
// screen's, or a thread window's.
Composer :: struct {
	buf:     []u8,
	len:     ^int,
	editing: ^proto.Msg_Id, // 0 for writing a new message
	conv:    ^proto.Conv_Id, // where the message being edited is
	thread:  int, // 0 for the page's, else the thread window's slot
}

composer_of_page :: proc(ui: ^UI) -> Composer {
	if ui.page == .Buddies {
		b := &ui.buddies
		return {b.buf[:], &b.len, &b.editing, &b.editing_conv, 0}
	}
	ch := &ui.chat
	return {ch.buf[:], &ch.len, &ch.editing, &ch.editing_conv, 0}
}

// composer_of is the page's composer (0) or a thread window's.
composer_of :: proc(ui: ^UI, thread: int) -> Composer {
	if thread == 0 {
		return composer_of_page(ui)
	}
	t := &ui.threads[thread - 1]
	return {t.buf[:], &t.len, &t.editing, &t.editing_conv, thread}
}

/*
composer_keys is what a composer does with Up and Escape, before its
text box is laid out: Up in an empty one starts editing our newest
message, and Escape stops editing (and empties it). A message being
edited in a conversation that isn't shown any more is let go. Call with
the View locked.
*/
composer_keys :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
	v := &ui.view
	if c.editing^ != 0 && c.conv^ != v.viewing {
		c.editing^ = 0
		c.len^ = 0
	}
	if ctx.focus_id != mu.get_id(ctx, uintptr(&c.buf[0])) {
		return
	}
	if .Escape in ui.keys && c.editing^ != 0 {
		c.editing^ = 0
		c.len^ = 0
	}
	if .Up in ui.keys && c.len^ == 0 && c.editing^ == 0 {
		key := conn.Timeline_Key{v.viewing, 0}
		if c.thread != 0 {
			key = ui.threads[c.thread - 1].key
		}
		if m, ok := newest_own_text(v, key); ok {
			start_editing(ui, m.id, m.text, c)
		}
	}
}

// composer_send sends what's in a composer: an edit, or a new message
// (for the DM with `dm_to`, if it's set; a thread window's in its
// thread). False if there was nothing to send.
composer_send :: proc(ui: ^UI, c: Composer, dm_to: proto.Account_Id = 0) -> bool {
	text := strings.trim_space(string(c.buf[:c.len^]))
	if text == "" || ui.session == nil {
		return false
	}
	text = conn.emoji_encode(conn.mentions_encode(text, ui.view.accounts), ui.view.emoji.names[:])
	cmds := &ui.session.client.commands
	if c.editing^ != 0 {
		log.debug("ui: edit a message")
		conn.push_command(cmds, conn.Edit_Command{id = c.editing^, text = strings.clone(text)})
		c.editing^ = 0
	} else {
		if c.thread != 0 {
			log.debug("ui: reply in a thread")
			t := &ui.threads[c.thread - 1]
			conn.push_command(cmds, conn.Chat_Command{text = strings.clone(text), thread = t.key})
			t.timeline.to_end = true
		} else {
			log.debug("ui: chat message")
			conn.push_command(cmds, conn.Chat_Command{text = strings.clone(text), dm_to = dm_to})
			ui.timeline.to_end = true
		}
	}
	c.len^ = 0
	return true
}

// composer_status is what the line over the conversation says about a
// composer, if anything: that it's editing.
composer_status :: proc(c: Composer) -> string {
	return "Editing a message: Enter saves it, Escape stops." if c.editing^ != 0 else ""
}
