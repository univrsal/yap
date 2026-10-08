package client

import log "common:wlog"
import "core:strings"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
A message's own menu, opened by right-clicking it in a timeline (a long
press on a touch screen): copy its text, save its picture, forward it,
copy a link to it. What's done to the message itself - reacting,
replying, editing, pinning, deleting - is on the bar over it instead
(ui_message_bar.odin), and the menu only asks whether to delete it when
the bar's Delete is pressed without Shift.
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
	// Delete was pressed on the bar: the menu only asks whether to.
	confirm:   bool,
}

@(private = "file")
MENU :: "message menu"
@(private = "file")
MENU_WIDTH :: 180

// open_message_menu opens the menu for a message shown in a timeline,
// or with `confirm_delete`, only the question whether to delete it.
// Call with the View locked.
open_message_menu :: proc(ui: ^UI, m: conn.View_Message, slot: int, confirm_delete := false) {
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
		confirm   = confirm_delete,
	}
}

// message_menu_open is whether the menu is open (or opens next frame).
message_menu_open :: proc(ui: ^UI) -> bool {
	if ui.msg_menu.requested {
		return true
	}
	cnt := mu.get_container(&ui.ctx, MENU, {.CLOSED})
	return cnt != nil && bool(cnt.open)
}

ui_message_menu_destroy :: proc(ui: ^UI) {
	delete(ui.msg_menu.text)
	ui.msg_menu = {}
	ui.msg_bar = {}
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
	v := ui.view
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
			close(ctx)
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
		shown, _ := conn.mentions_display(mm.text, v.accounts, v.roles[:], v.me)
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
}

// start_editing loads one of our messages into a composer, to be edited
// there.
start_editing :: proc(ui: ^UI, id: proto.Msg_Id, text: string, c: Composer) {
	c.len^ = copy(c.buf, conn.mentions_for_edit(text, ui.view.accounts, ui.view.roles[:]))
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
	files:   ^[dynamic]Picked_File, // what goes with it (ui_attachments.odin)
	area:    ^Text_Area, // the box it's written in
}

composer_of_page :: proc(ui: ^UI) -> Composer {
	if ui.page == .Buddies {
		b := &ui.buddies
		return {b.buf[:], &b.len, &b.editing, &b.editing_conv, 0, &b.files, &b.area}
	}
	ch := &ui.chat
	return {ch.buf[:], &ch.len, &ch.editing, &ch.editing_conv, 0, &ch.files, &ch.area}
}

// composer_of is the page's composer (0) or a thread window's.
composer_of :: proc(ui: ^UI, thread: int) -> Composer {
	if thread == 0 {
		return composer_of_page(ui)
	}
	t := &ui.threads[thread - 1]
	return {t.buf[:], &t.len, &t.editing, &t.editing_conv, thread, &t.files, &t.area}
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
	v := ui.view
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
	composer_format(ui, c)
	if .Up in ui.keys && c.len^ == 0 && c.editing^ == 0 {
		key := conn.Timeline_Key{v.viewing, 0}
		if c.thread != 0 {
			key = ui.threads[c.thread - 1].key
		}
		if m, ok := newest_own_text(v, key); ok {
			start_editing(ui, m.id, m.text, c)
			ui.keys -= {.Up} // not for the text area as well
		}
	}
}

/*
composer_format does the markdown keys (Ctrl+B, Ctrl+I, Ctrl+U,
Ctrl+Shift+X, Ctrl+E) in a composer with the focus: the markers go round
the selection, or come off it (conn.markdown_toggle). Nothing happens if
the text wouldn't fit.
*/
@(private = "file")
composer_format :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
	MARKERS :: [?]struct {
		key:    Extra_Key,
		marker: string,
	}{{.Bold, "**"}, {.Italic, "*"}, {.Underline, "__"}, {.Strike, "~~"}, {.Code, "`"}}
	for k in MARKERS {
		if k.key not_in ui.keys {
			continue
		}
		ui.keys -= {k.key}
		s := &ctx.textbox_state
		sel := [2]int{c.len^, c.len^}
		if s.id == u64(mu.get_id(ctx, uintptr(&c.buf[0]))) {
			sel = {clamp(s.selection[0], 0, c.len^), clamp(s.selection[1], 0, c.len^)}
		}
		out, lo, hi := conn.markdown_toggle(
			string(c.buf[:c.len^]),
			min(sel[0], sel[1]),
			max(sel[0], sel[1]),
			k.marker,
		)
		if len(out) > len(c.buf) {
			continue
		}
		c.len^ = copy(c.buf, out)
		// The caret stays at the end it was at.
		s.selection = {hi, lo} if sel[0] >= sel[1] else {lo, hi}
	}
}

// composer_send sends what's in a composer: an edit, or a new message
// (for the DM with `dm_to`, if it's set; a thread window's in its
// thread). False if there was nothing to send.
composer_send :: proc(ui: ^UI, c: Composer, dm_to: proto.Account_Id = 0) -> bool {
	text := strings.trim_space(string(c.buf[:c.len^]))
	has_files := c.files != nil && len(c.files) > 0 && c.editing^ == 0
	if (text == "" && !has_files) || ui.session == nil {
		return false
	}
	ui_redraw(ui) // for the box to shrink back to a line
	c.area.preview = false
	text = conn.emoji_encode(
		conn.mentions_encode(text, ui.view.accounts, ui.view.roles[:]),
		ui.view.emoji.names[:],
	)
	if has_files {
		log.debug("ui: a message with files")
		composer_send_files(ui, c, text, dm_to)
		c.len^ = 0
		return true
	}
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
