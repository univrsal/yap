package server

import "core:log"
import "core:slice"

import "common:proto"
import "sqlite"

// Changing messages after they have been posted (see
// src/common/proto/msgs.odin): editing, deleting and pinning, and listing
// the pins of a conversation.
//
//	Edit    Only the author, only text messages, and not deleted ones.
//	Delete  The author or an account with Manage_Messages. Deleting twice is
//	        not an error.
//	Pin     Either member of a DM, or an account with Pin_Messages in a
//	        channel. A conversation can have at most proto.MAX_PINS pins.
//
// All of these are only available to members of the message's conversation.
// Anyone else gets the answer that the message doesn't exist (Not_Found),
// the same as for a conversation they can't see. Each change is sent to
// every connection of every member as Msg_Changed, containing the message
// as it is now.
//
// A deleted message keeps its row so that ids, read markers and threads
// stay valid, but its text, picture and file are removed. Nothing can be
// fetched through it any more (blob_visible only looks at the messages that
// reference a picture). It is also unpinned, and a file it offered can no
// longer be accepted.

// msg_of_member returns message `id` and its conversation if the
// connection's account is a member of that conversation. Otherwise it
// returns the status that explains why not.
@(private = "file")
msg_of_member :: proc(
	s: ^Server,
	u: ^Conn,
	id: proto.Msg_Id,
) -> (
	m: proto.Message,
	conv: ^Conv,
	status: proto.Status,
) {
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

// msg_by_id reads one message. Its strings are allocated with the temp allocator.
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
		// Forwarded messages can't be edited either, since they are copies of
		// somebody else's words (see proto/forward.odin).
		respond(u, id, .Invalid)
		return
	}
	text_buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, text_buf[:])
	if text == "" {
		respond(u, id, .Invalid)
		return
	}
	kept, mentioned := mentions_resolve(s, u, conv, links_restrict(s, conv, text), m.id - 1)
	if len(kept) > proto.MAX_CHAT_SIZE {
		respond(u, id, .Too_Large) // see msg_post
		return
	}
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
	// Accounts that the edit started or stopped mentioning now have a
	// different mention count.
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
	ok_files := db_run(&s.db, clear_files)
	unindex := db_stmt(&s.db, .Files_Index_Remove)
	db_bind_int(unindex, 1, i64(m.id))
	if !db_run(&s.db, q) || !ok_files || !db_run(&s.db, unindex) || !mentions_clear(s, m.id) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok)
	log.debugf("%s deleted message %d", conn_label(u), m.id)
	// Only the fact that the message existed is kept. Everything else is removed.
	m.flags = m.flags + {.Deleted} - {.Pinned, .Has_Attachments}
	m.text, m.file_name, m.file_size = "", "", 0
	m.attachment_count = 0
	m.reaction_count, m.reactions = 0, nil
	msg_deliver(s, conv, m, .Msg_Changed)
	mentions_changed(s, conv, m.id, mentioned)
	if m.thread_root != 0 {
		thread_changed(s, conv, m.thread_root)
	}
}

// may_pin returns whether an account may pin and unpin messages in a
// conversation it is a member of.
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
		// Replies in a thread can't be pinned because pins belong to the
		// conversation as a whole.
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

// pins_get answers with the pinned messages of a conversation, with the
// most recent pin first.
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

// thread_changed recounts the replies of a thread's root message (after a
// reply was posted or deleted) and sends the updated root message to
// everyone. This includes its reply count, its last reply and whether it
// still has a thread at all.
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
