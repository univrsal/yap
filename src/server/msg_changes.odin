package server

import "core:log"
import "core:slice"

import "common:proto"
import "sqlite"

/*
Changing messages after they're posted (src/common/proto/msgs.odin):
editing, deleting and pinning, and the pins of a conversation.

	Edit    the author, a text message, not deleted
	Delete  the author, or Manage_Messages; idempotent
	Pin     either member of a DM; Pin_Messages in a channel; at most
	        proto.MAX_PINS in a conversation

All of them are for members of the message's conversation; one that
isn't is told the message isn't there (Not_Found), as for a
conversation it can't see. Each change goes to every connection of every
member as Msg_Changed, the message as it now is.

A deleted message keeps its row, so ids, read markers and (later)
threads hold, but its text, picture and file are gone from it: nothing
can fetch them through it any more (blob_visible goes by the messages
that name a picture). It's unpinned, and a file it offered can't be
taken up.
*/

// msg_of_member is message `id` if the connection's account is a member
// of its conversation, with the conversation; else why not.
@(private = "file")
msg_of_member :: proc(s: ^Server, u: ^Conn, id: proto.Msg_Id) -> (m: proto.Message, conv: ^Conv, status: proto.Status) {
	found: bool
	m, found = msg_by_id(s, id)
	if !found {
		return {}, nil, .Not_Found
	}
	conv = conv_by_id(&s.convs, m.conv)
	if conv == nil || !conv_is_member(conv, u.account.id) || .Archived in conv.flags {
		return {}, nil, .Not_Found
	}
	return m, conv, .Ok
}

// msg_by_id reads one message; its strings are in the temp allocator.
msg_by_id :: proc(s: ^Server, id: proto.Msg_Id) -> (m: proto.Message, found: bool) {
	q := db_stmt(&s.db, .Msg_By_Id)
	db_bind_int(q, 1, i64(id))
	row, ok := db_step(&s.db, q)
	if !ok || !row {
		return
	}
	m = msg_of_row(q)
	sqlite.reset(q)
	attach_reactions(s, &m, 0)
	attach_files(s, &m)
	return m, true
}

msg_edit :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, raw, ok := proto.decode_msg_edit(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	m, conv, status := msg_of_member(s, u, msg_id)
	switch {
	case conv == nil:
		respond(u, id, status)
		return
	case m.sender != u.account.id:
		respond(u, id, .Denied)
		return
	case m.kind != .Text || .Deleted in m.flags || .Forwarded in m.flags:
		// Nor a copy of somebody else's words (proto/forward.odin).
		respond(u, id, .Invalid)
		return
	}
	text_buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_text(raw, text_buf[:])
	if text == "" {
		respond(u, id, .Invalid)
		return
	}
	kept, mentioned := mentions_resolve(s, u, conv, links_restrict(s, conv, text), m.id - 1)
	if kept == m.text {
		respond(u, id, .Ok)
		return
	}
	before := mentioned_in(s, m.id)
	m.text = kept
	m.edited = proto.Unix_Ms(unix_ms())
	q := db_stmt(&s.db, .Msg_Edit)
	db_bind_int(q, 1, i64(m.id))
	db_bind_text(q, 2, m.text)
	db_bind_int(q, 3, i64(m.edited))
	if !db_run(&s.db, q) || !mentions_store(s, conv, m.id, mentioned) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	log.debugf("%s edited message %d", conn_label(u), m.id)
	msg_deliver(s, conv, m, .Msg_Changed)
	// Those it stopped or started mentioning count it differently now.
	changed := make([dynamic]proto.Account_Id, context.temp_allocator)
	for a in before {
		if !slice.contains(mentioned, a) {
			append(&changed, a)
		}
	}
	for a in mentioned {
		if !slice.contains(before, a) {
			append(&changed, a)
		}
	}
	mentions_changed(s, conv, m.id, changed[:])
}

msg_delete :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, ok := proto.decode_msg_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	m, conv, status := msg_of_member(s, u, msg_id)
	switch {
	case conv == nil:
		respond(u, id, status)
		return
	case m.sender != u.account.id && !can(u.account, .Manage_Messages):
		respond(u, id, .Denied)
		return
	case .Deleted in m.flags:
		respond(u, id, .Ok)
		return
	}
	q := db_stmt(&s.db, .Msg_Delete)
	db_bind_int(q, 1, i64(m.id))
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	if .Pinned in m.flags {
		q = db_stmt(&s.db, .Pin_Remove)
		db_bind_int(q, 1, i64(conv.id))
		db_bind_int(q, 2, i64(m.id))
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
	}
	forget_offer(s, m.id)
	mentioned := mentioned_in(s, m.id)
	q = db_stmt(&s.db, .React_Clear)
	db_bind_int(q, 1, i64(m.id))
	clear_files := db_stmt(&s.db, .Attach_Clear)
	db_bind_int(clear_files, 1, i64(m.id))
	if !db_run(&s.db, q) || !db_run(&s.db, clear_files) || !mentions_clear(s, m.id) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	log.debugf("%s deleted message %d", conn_label(u), m.id)
	// As it now is: nothing left of it but that it was there.
	m.flags = m.flags + {.Deleted} - {.Pinned, .Has_Attachments}
	m.text, m.file_name, m.file_size, m.image = "", "", 0, {}
	m.attachment_count = 0
	m.reaction_count, m.reactions = 0, nil
	msg_deliver(s, conv, m, .Msg_Changed)
	mentions_changed(s, conv, m.id, mentioned)
	if m.thread_root != 0 {
		thread_changed(s, conv, m.thread_root)
	}
}

// may_pin is whether an account may pin and unpin in a conversation it's
// a member of.
may_pin :: proc(acc: ^Account, conv: ^Conv) -> bool {
	return conv.kind == .DM || can(acc, .Pin_Messages)
}

msg_pin :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	msg_id, on, ok := proto.decode_msg_pin(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	m, conv, status := msg_of_member(s, u, msg_id)
	switch {
	case conv == nil:
		respond(u, id, status)
		return
	case !may_pin(u.account, conv):
		respond(u, id, .Denied)
		return
	case .Deleted in m.flags || m.thread_root != 0:
		// Nor a reply in a thread: what's pinned is the conversation's.
		respond(u, id, .Invalid)
		return
	case on == (.Pinned in m.flags):
		respond(u, id, .Ok)
		return
	}
	if on {
		q := db_stmt(&s.db, .Pin_Count)
		db_bind_int(q, 1, i64(conv.id))
		count := 0
		if row, stepped := db_step(&s.db, q); stepped && row {
			count = int(db_col_int(q, 0))
			sqlite.reset(q)
		}
		if count >= proto.MAX_PINS {
			respond(u, id, .Too_Large)
			return
		}
		q = db_stmt(&s.db, .Pin_Add)
		db_bind_int(q, 1, i64(conv.id))
		db_bind_int(q, 2, i64(m.id))
		db_bind_int(q, 3, i64(u.account.id))
		db_bind_int(q, 4, unix_ms())
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
		m.flags += {.Pinned}
	} else {
		q := db_stmt(&s.db, .Pin_Remove)
		db_bind_int(q, 1, i64(conv.id))
		db_bind_int(q, 2, i64(m.id))
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
		m.flags -= {.Pinned}
	}
	q := db_stmt(&s.db, .Msg_Set_Flags)
	db_bind_int(q, 1, i64(m.id))
	db_bind_int(q, 2, i64(transmute(u8)m.flags))
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	log.debugf("%s %s message %d", conn_label(u), "pinned" if on else "unpinned", m.id)
	msg_deliver(s, conv, m, .Msg_Changed)
}

// pins_get answers with a conversation's pinned messages, the newest pin
// first.
pins_get :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	conv_id, ok := proto.decode_conv_id(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_visible(conv, u.account.id) {
		respond(u, id, .Not_Found)
		return
	}
	if !conv_is_member(conv, u.account.id) {
		respond(u, id, .Denied)
		return
	}
	list := make([dynamic]proto.Message, 0, proto.MAX_PINS, context.temp_allocator)
	q := db_stmt(&s.db, .Pins_Of)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, proto.MAX_PINS)
	for {
		row, stepped := db_step(&s.db, q)
		if !stepped {
			respond(u, id, .Internal)
			return
		}
		if !row {
			break
		}
		append(&list, msg_of_row(q))
	}
	for &m in list {
		attach_reactions(s, &m, u.account.id)
		attach_files(s, &m)
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_message_list(out, list[:]))
}

/*
thread_changed counts a thread's root's replies again (posting one,
deleting one) and tells everyone the root as it now is: its reply count,
its last reply, and whether it has a thread at all.
*/
thread_changed :: proc(s: ^Server, conv: ^Conv, root: proto.Msg_Id) {
	q := db_stmt(&s.db, .Thread_Recount)
	db_bind_int(q, 1, i64(root))
	if !db_run(&s.db, q) {
		return
	}
	if m, found := msg_by_id(s, root); found {
		msg_deliver(s, conv, m, .Msg_Changed)
	}
}
