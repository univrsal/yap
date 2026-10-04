package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

/*
Messages (src/common/proto/msgs.odin): posted to a conversation, kept in
the database for good, and read back a page at a time.

Only a conversation's members post to it and read it. A message that is
posted goes, as Msg_New, to every connection of every member there and
then, the poster's own included: its other devices want it too, and the
one that posted matches it to what it sent by the id in the answer.
Nothing is replayed later; a client that was away asks for what it
missed (Msg_History).

A post carries a nonce of the poster's. The database keeps it, and a
post that comes again with the same one (the client repeated it after
its connection started over) is answered with the message it already is.

Pictures are blobs (blobs.odin, transfers.odin); a message names one.
A text message may carry files that were uploaded for it
(attachments.odin), which a post names by their uploads.
A file is offered in a DM by a message that names it and says how big
it is; the file itself goes between the two clients (files.odin).

The first message in a DM is when the other account hears of it: its
connections are told of the conversation (Conv_Changed) just before
the message comes.
*/

// Typing notices from one connection are passed on at most this often.
TYPING_RELAY_INTERVAL :: 500 * time.Millisecond

// message_request handles a request about messages or blobs; false if
// `op` isn't one.
message_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Msg_Post:
		msg_post(s, u, id, body)
	case .Msg_History:
		msg_history(s, u, id, body)
	case .Msg_Edit:
		msg_edit(s, u, id, body)
	case .Msg_Delete:
		msg_delete(s, u, id, body)
	case .Msg_Pin:
		msg_pin(s, u, id, body)
	case .Msg_Forward:
		msg_forward(s, u, id, body)
	case .Msg_Search:
		msg_search(s, u, id, body)
	case .Msg_React:
		msg_react(s, u, id, body)
	case .Reactors_Get:
		reactors_get(s, u, id, body)
	case .Pins_Get:
		pins_get(s, u, id, body)
	case .Blob_Put:
		blob_put_request(s, u, id, body)
	case .Blob_Get:
		blob_get_request(s, u, id, body)
	case .Attach_Put:
		attach_put_request(s, u, id, body)
	case .Attach_Get:
		attach_get_request(s, u, id, body)
	case .Purge:
		purge_request(s, u, id, body)
	case:
		return false
	}
	return true
}

// conv_of_member is the conversation `conv_id` if the connection's
// account is a member, else why not.
conv_of_member :: proc(s: ^Server, u: ^Conn, conv_id: proto.Conv_Id) -> (^Conv, proto.Status) {
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_visible(conv, u.account.id) {
		return nil, .Not_Found
	}
	if !conv_is_member(conv, u.account.id) {
		return nil, .Denied
	}
	return conv, .Ok
}

@(private = "file")
msg_post :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	p, ok := proto.decode_msg_post(body)
	// A nonce of 0 couldn't tell a repeat.
	if !ok || p.nonce == 0 {
		respond(u, id, .Invalid)
		return
	}
	conv, status := conv_of_member(s, u, p.conv)
	if conv == nil {
		respond(u, id, status)
		return
	}
	// A reply goes to a thread's root: a message of this conversation
	// that isn't deleted. A reply to a reply goes to its root.
	root: proto.Message
	if p.thread_root != 0 {
		found: bool
		root, found = msg_by_id(s, p.thread_root)
		if found && root.thread_root != 0 {
			root, found = msg_by_id(s, root.thread_root)
		}
		if !found || root.conv != conv.id || .Deleted in root.flags {
			respond(u, id, .Invalid)
			return
		}
	}
	sender := u.account.id
	posted: [proto.MSG_POSTED_SIZE]u8

	// Posted already, and the answer lost with the connection.
	if prev, at, found := msg_by_nonce(&s.db, sender, p.nonce); found {
		respond(u, id, .Ok, proto.encode_msg_posted(&posted, prev, at))
		return
	}

	m := proto.Message {
		conv        = conv.id,
		sender      = sender,
		kind        = p.kind,
		thread_root = root.id,
	}
	text_buf: [proto.MAX_CHAT_SIZE]u8
	name_buf: [proto.MAX_FILE_NAME]u8
	mentioned: []proto.Account_Id
	#partial switch p.kind {
	case .File:
		// Only between two people, and only what may be sent.
		m.file_name = proto.sanitize_file_name(p.text, &name_buf)
		m.file_size = p.file_size
		if conv.kind != .DM ||
		   m.file_size == 0 ||
		   m.file_name == "" ||
		   !proto.file_type_allowed(m.file_name) {
			respond(u, id, .Invalid)
			return
		}
	case .Text:
		m.text = proto.sanitize_message(p.text, text_buf[:])
		// The files it carries: uploads of the poster's, each once.
		for i in 0 ..< p.attachment_count {
			up, kept := attach_upload_for(s, sender, p.uploads[i])
			if !kept {
				respond(u, id, .Not_Found)
				return
			}
			for j in 0 ..< i {
				if p.uploads[j] == p.uploads[i] {
					respond(u, id, .Invalid)
					return
				}
			}
			m.attachments[i] = {
				blob = up.blob,
				size = up.size,
				name = up.name,
			}
		}
		m.attachment_count = p.attachment_count
		if m.attachment_count > 0 {
			m.flags += {.Has_Attachments}
		} else if m.text == "" {
			respond(u, id, .Invalid)
			return
		}
		// Before it's stored: whoever is subscribed by being mentioned
		// hasn't read it.
		m.text, mentioned = mentions_resolve(s, u, conv, links_restrict(s, conv, m.text), conv.last_msg)
	case .Image:
		b, found := blob_get(&s.blobs, p.blob)
		if !found || b.kind != .Image {
			respond(u, id, .Not_Found)
			return
		}
		m.image = {
			blob   = b.id,
			width  = u16(b.width),
			height = u16(b.height),
			size   = u32(b.size),
		}
	}
	first := conv.last_msg == 0
	if !msg_store(s, conv, &m, p.nonce) || !mentions_store(s, conv, m.id, mentioned) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok, proto.encode_msg_posted(&posted, m.id, m.time))
	// Message content stays out of the log unless debugging.
	place := conv.name if conv.kind == .Channel else fmt.tprintf("a DM with account %d", dm_other(conv, sender))
	#partial switch m.kind {
	case .Text:
		log.debugf("%s in %q: %s (%d files)", conn_label(u), place, m.text, m.attachment_count)
	case .Image:
		log.debugf("%s in %q: a picture (blob %d)", conn_label(u), place, m.image.blob)
	case .File:
		log.debugf("%s in %q: offers %q (%d bytes)", conn_label(u), place, m.file_name, m.file_size)
		file_offered(s, u, conv, m)
	}
	if first && conv.kind == .DM {
		// News to the other one, which is told of the conversation
		// before the message in it. Told as it was before the message,
		// which then counts as unread like any other.
		other := dm_other(conv, sender)
		last := conv.last_msg
		conv.last_msg = 0
		send_conv_to_account(s, other, conv)
		conv.last_msg = last
	}
	msg_deliver(s, conv, m)
	if root.id != 0 {
		thread_changed(s, conv, root.id)
	}
	// Whoever posts has read what came before.
	if conv_set_read(&s.convs, conv, sender, m.id) {
		send_read(s, u.account, conv)
	}
}

/*
links_restrict keeps links to a DM's messages (proto/forward.odin) in
that DM: anywhere else, only its two could follow one, so it's written
as plain text. In the temp allocator, or `text` if there's nothing to
change.
*/
links_restrict :: proc(s: ^Server, conv: ^Conv, text: string) -> string {
	out := text
	at := 0
	for {
		l, ok := proto.next_link(out, at)
		if !ok {
			return out
		}
		at = l.end
		linked := conv_by_id(&s.convs, l.conv)
		if l.conv == conv.id || linked == nil || linked.kind != .DM {
			continue
		}
		plain := "(a message in a DM)"
		out = strings.concatenate({out[:l.start], plain, out[l.end:]}, context.temp_allocator)
		at = l.start + len(plain)
	}
}

/*
msg_forward copies a message the account may read to a conversation it
may post to (proto/forward.odin): its content, with where it came from.
A forward repeated with the same nonce is answered as a post is.
*/
@(private = "file")
msg_forward :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	f, ok := proto.decode_msg_forward(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv, status := conv_of_member(s, u, f.conv)
	if conv == nil {
		respond(u, id, status)
		return
	}
	src, found := msg_by_id(s, f.msg)
	src_conv := conv_by_id(&s.convs, src.conv) if found else nil
	if src_conv == nil || !conv_is_member(src_conv, u.account.id) || .Archived in src_conv.flags {
		respond(u, id, .Not_Found)
		return
	}
	if .Deleted in src.flags || (src.kind != .Text && src.kind != .Image) || (src.kind == .Image && src.image.blob == 0) {
		respond(u, id, .Invalid)
		return
	}
	// Into a thread: its root has to be this conversation's, as a post's.
	root: proto.Message
	if f.thread_root != 0 {
		root, found = msg_by_id(s, f.thread_root)
		if found && root.thread_root != 0 {
			root, found = msg_by_id(s, root.thread_root)
		}
		if !found || root.conv != conv.id || .Deleted in root.flags {
			respond(u, id, .Invalid)
			return
		}
	}
	posted: [proto.MSG_POSTED_SIZE]u8
	if prev, at, again := msg_by_nonce(&s.db, u.account.id, f.nonce); again {
		respond(u, id, .Ok, proto.encode_msg_posted(&posted, prev, at))
		return
	}
	// The original's author, where and when; a copy's are its original's.
	from := proto.Forward_Info{src.sender, src.conv, src.time}
	if .Forwarded in src.flags {
		from = src.forward
	}
	m := proto.Message {
		conv        = conv.id,
		sender      = u.account.id,
		kind        = src.kind,
		flags       = {.Forwarded},
		thread_root = root.id,
		text        = links_restrict(s, conv, src.text),
		image       = src.image,
		forward     = from,
		attachment_count = src.attachment_count,
		attachments = src.attachments,
	}
	if .Has_Attachments in src.flags {
		m.flags += {.Has_Attachments}
	}
	first := conv.last_msg == 0
	if !msg_store(s, conv, &m, f.nonce) {
		respond(u, id, .Internal)
		return
	}
	respond(u, id, .Ok, proto.encode_msg_posted(&posted, m.id, m.time))
	log.debugf("%s forwarded message %d to conversation %d", conn_label(u), src.id, conv.id)
	if first && conv.kind == .DM {
		other := dm_other(conv, u.account.id)
		last := conv.last_msg
		conv.last_msg = 0
		send_conv_to_account(s, other, conv)
		conv.last_msg = last
	}
	msg_deliver(s, conv, m)
	if root.id != 0 {
		thread_changed(s, conv, root.id)
	}
	if conv_set_read(&s.convs, conv, u.account.id, m.id) {
		send_read(s, u.account, conv)
	}
}

/*
msg_store adds a message to the database, filling in its id and time,
and makes it its conversation's last. `m` has its conversation, sender,
kind and content.
*/
msg_store :: proc(s: ^Server, conv: ^Conv, m: ^proto.Message, nonce: u64) -> bool {
	m.time = proto.Unix_Ms(unix_ms())
	q := db_stmt(&s.db, .Msg_Add)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(m.sender))
	db_bind_int(q, 3, i64(m.time))
	db_bind_int(q, 4, i64(m.kind))
	#partial switch m.kind {
	case .Text:
		db_bind_text(q, 5, m.text)
	case .File:
		db_bind_text(q, 5, m.file_name)
	case .System:
		// What happened, as a number; its argument where a file's size
		// goes.
		db_bind_text(q, 5, fmt.tprint(m.system))
	case:
		db_bind_null(q, 5)
	}
	if m.kind == .Image {
		db_bind_int(q, 6, i64(m.image.blob))
	} else {
		db_bind_null(q, 6)
	}
	if nonce != 0 {
		db_bind_int(q, 7, i64(nonce))
	} else {
		db_bind_null(q, 7) // the server's own, which no client repeats
	}
	db_bind_int(q, 8, i64(m.system_arg) if m.kind == .System else i64(m.file_size))
	db_bind_int(q, 9, i64(m.thread_root))
	db_bind_int(q, 10, i64(transmute(u8)m.flags))
	db_bind_int(q, 11, i64(m.forward.sender))
	db_bind_int(q, 12, i64(m.forward.conv))
	db_bind_int(q, 13, i64(m.forward.time))
	db_run(&s.db, q) or_return
	m.id = proto.Msg_Id(db_last_id(&s.db))
	attachments_store(s, m^) or_return
	if conv.kind == .DM {
		conv.posted[0 if m.sender == conv.a else 1] = true
	}

	q = db_stmt(&s.db, .Conv_Set_Last)
	db_bind_int(q, 1, i64(conv.id))
	db_bind_int(q, 2, i64(m.id))
	db_run(&s.db, q) or_return
	conv.last_msg = m.id
	return true
}

// msg_by_nonce is the message `sender` posted with `nonce`, if there's one.
@(private = "file")
msg_by_nonce :: proc(
	db: ^DB,
	sender: proto.Account_Id,
	nonce: u64,
) -> (
	id: proto.Msg_Id,
	at: proto.Unix_Ms,
	found: bool,
) {
	q := db_stmt(db, .Msg_By_Nonce)
	db_bind_int(q, 1, i64(sender))
	db_bind_int(q, 2, i64(nonce))
	row, ok := db_step(db, q)
	if !ok || !row {
		return
	}
	id = proto.Msg_Id(db_col_int(q, 0))
	at = proto.Unix_Ms(db_col_int(q, 1))
	sqlite.reset(q)
	return id, at, true
}

// msg_deliver sends a message to every connection of every member of
// its conversation: a new one, or (`op` Msg_Changed) one as it now is.
msg_deliver :: proc(s: ^Server, conv: ^Conv, m: proto.Message, op := proto.Event_Op.Msg_New) {
	buf: [proto.MESSAGE_MAX_SIZE]u8
	body := proto.encode_message(buf[:], m)
	if body == nil {
		log.errorf("message %d doesn't fit in a record", m.id)
		return
	}
	for member in conv.members {
		acc := s.accounts.by_id[member] or_else nil
		if acc == nil {
			continue
		}
		for c in acc.conns {
			send_event(c, op, body)
		}
	}
}

/*
msg_history answers with a page of a conversation's messages, oldest
first (see proto.History_Dir for which).
*/
@(private = "file")
msg_history :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	h, ok := proto.decode_msg_history(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	conv, status := conv_of_member(s, u, h.conv)
	if conv == nil {
		respond(u, id, status)
		return
	}
	// A thread's replies: its root has to be a message of this
	// conversation.
	if h.thread_root != 0 {
		if root, found := msg_by_id(s, h.thread_root); !found || root.conv != conv.id || root.thread_root != 0 {
			respond(u, id, .Not_Found)
			return
		}
	}
	msgs, more, read_ok := history_page(s, conv.id, h.anchor, h.dir, h.limit, u.account.id, h.thread_root)
	if !read_ok {
		respond(u, id, .Internal)
		return
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	page, _ := proto.encode_history_page(out, more, msgs)
	respond(u, id, .Ok, page)
}

/*
history_page reads up to `limit` messages of a conversation next to
`anchor`, oldest first, and says whether there are more beyond them
either way. It keeps to what fits in one answer, dropping from the far
end from the anchor. The messages' strings are in the temp allocator.
*/
history_page :: proc(
	s: ^Server,
	conv: proto.Conv_Id,
	anchor: proto.Msg_Id,
	dir: proto.History_Dir,
	limit: int,
	asker: proto.Account_Id, // whose own reactions are marked
	thread_root: proto.Msg_Id = 0, // a thread's replies, rather than the whole conversation
) -> (
	msgs: []proto.Message,
	more: u8,
	ok: bool,
) {
	list := make([dynamic]proto.Message, 0, limit + 2, context.temp_allocator)
	// The statements for one or the other, and what they're asked about.
	thread := thread_root != 0
	before := Stmt.Thread_Before if thread else .Msg_Before
	after := Stmt.Thread_After if thread else .Msg_After
	any_before := Stmt.Thread_Any_Before if thread else .Msg_Any_Before
	any_after := Stmt.Thread_Any_After if thread else .Msg_Any_After
	// For a thread, the statements ask by the root, in the place of the
	// conversation.
	scope := proto.Conv_Id(thread_root) if thread else conv
	switch dir {
	case .Before:
		// Newest first, one more than asked for, to know if there are more.
		upto := i64(anchor) if anchor != 0 else max(i64)
		msgs_read(s, before, scope, upto, limit + 1, &list) or_return
		if len(list) > limit {
			more |= proto.MORE_BEFORE
			pop(&list)
		}
		slice.reverse(list[:])
		if anchor != 0 && msg_any(s, any_after, scope, anchor - 1) {
			more |= proto.MORE_AFTER
		}
	case .After:
		msgs_read(s, after, scope, i64(anchor), limit + 1, &list) or_return
		if len(list) > limit {
			more |= proto.MORE_AFTER
			pop(&list)
		}
		if msg_any(s, any_before, scope, anchor + 1) {
			more |= proto.MORE_BEFORE
		}
	case .Around:
		// The anchor and the older half, then the newer half.
		older := (limit + 1) / 2
		msgs_read(s, before, scope, i64(anchor) + 1, older + 1, &list) or_return
		if len(list) > older {
			more |= proto.MORE_BEFORE
			pop(&list)
		}
		slice.reverse(list[:])
		newer := limit - len(list)
		if newer > 0 {
			before := len(list)
			msgs_read(s, after, scope, i64(anchor), newer + 1, &list) or_return
			if len(list) - before > newer {
				more |= proto.MORE_AFTER
				pop(&list)
			}
		} else if msg_any(s, any_after, scope, anchor) {
			more |= proto.MORE_AFTER
		}
	}

	for &m in list {
		attach_reactions(s, &m, asker)
		attach_files(s, &m)
	}
	// A page of long messages (with files and reactions) can be too big
	// for one answer: what's furthest from the anchor goes.
	msgs = list[:]
	size := proto.HISTORY_HEADER_SIZE
	for m in msgs {
		size += proto.message_size(m)
	}
	// Around: where the anchor is in the page, to keep the page about it.
	at := len(msgs) / 2
	for m, i in msgs {
		if m.id == anchor {
			at = i
		}
	}
	for size > proto.MAX_BODY_SIZE && len(msgs) > 0 {
		newer_side := dir == .After || (dir == .Around && len(msgs) - 1 - at > at)
		if newer_side {
			size -= proto.message_size(msgs[len(msgs) - 1])
			msgs = msgs[:len(msgs) - 1]
			more |= proto.MORE_AFTER
		} else {
			size -= proto.message_size(msgs[0])
			msgs = msgs[1:]
			at -= 1
			more |= proto.MORE_BEFORE
		}
	}
	return msgs, more, true
}

// msgs_read appends up to `limit` messages from one of the history
// statements.
@(private = "file")
msgs_read :: proc(
	s: ^Server,
	stmt: Stmt,
	conv: proto.Conv_Id,
	anchor: i64,
	limit: int,
	out: ^[dynamic]proto.Message,
) -> bool {
	q := db_stmt(&s.db, stmt)
	db_bind_int(q, 1, i64(conv))
	db_bind_int(q, 2, anchor)
	db_bind_int(q, 3, i64(limit))
	for {
		row, ok := db_step(&s.db, q)
		if !ok {
			return false
		}
		if !row {
			return true
		}
		append(out, msg_of_row(q))
	}
}

// msg_any is whether one of the statements that look for a message
// before or after an id finds one.
@(private = "file")
msg_any :: proc(s: ^Server, stmt: Stmt, conv: proto.Conv_Id, id: proto.Msg_Id) -> bool {
	q := db_stmt(&s.db, stmt)
	db_bind_int(q, 1, i64(conv))
	db_bind_int(q, 2, i64(id))
	row, ok := db_step(&s.db, q)
	if ok && row {
		sqlite.reset(q)
		return true
	}
	return false
}

// blob_visible is whether an account may fetch a blob: a message it may
// read shows it.
blob_visible :: proc(s: ^Server, account: proto.Account_Id, blob: Blob_Id) -> bool {
	q := db_stmt(&s.db, .Msg_Blob_Convs)
	db_bind_int(q, 1, i64(blob))
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			return false
		}
		conv := conv_by_id(&s.convs, proto.Conv_Id(db_col_int(q, 0)))
		if conv != nil && conv_is_member(conv, account) {
			sqlite.reset(q)
			return true
		}
	}
}

// handle_typing tells the other members of a conversation who are here
// that someone is typing in it.
handle_typing :: proc(s: ^Server, from: ^Conn, pt: []u8) {
	now := time.tick_now()
	if from.last_typing != {} && time.tick_diff(from.last_typing, now) < TYPING_RELAY_INTERVAL {
		return
	}
	conv_id, root := proto.decode_typing_up(pt)
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_is_member(conv, from.account.id) {
		return
	}
	from.last_typing = now

	buf: [proto.TYPING_DOWN_SIZE]u8
	msg := proto.encode_typing_down(&buf, conv_id, root, from.account.id)
	for member in conv.members {
		acc := s.accounts.by_id[member] or_else nil
		if acc == nil || acc == from.account {
			continue
		}
		for u in acc.conns {
			if c := sending_session(s, u); c != nil {
				send_message(s, c, msg)
			}
		}
	}
}

// msg_of_row is a message as one of the statements that read whole
// messages has it; its strings are in the temp allocator.
msg_of_row :: proc(q: ^sqlite.Stmt) -> proto.Message {
	m := proto.Message {
		id          = proto.Msg_Id(db_col_int(q, 0)),
		conv        = proto.Conv_Id(db_col_int(q, 1)),
		sender      = proto.Account_Id(db_col_int(q, 2)),
		time        = proto.Unix_Ms(db_col_int(q, 3)),
		kind        = proto.Msg_Kind(db_col_int(q, 4)),
		flags       = transmute(proto.Msg_Flags)u8(db_col_int(q, 5)),
		thread_root = proto.Msg_Id(db_col_int(q, 6)),
		edited      = proto.Unix_Ms(db_col_int(q, 7)),
		reply_count = u32(db_col_int(q, 13)),
		last_reply  = proto.Msg_Id(db_col_int(q, 14)),
	}
	if .Forwarded in m.flags {
		m.forward = {
			sender = proto.Account_Id(db_col_int(q, 16)),
			conv   = proto.Conv_Id(db_col_int(q, 17)),
			time   = proto.Unix_Ms(db_col_int(q, 18)),
		}
	}
	#partial switch m.kind {
	case .Text:
		m.text = db_col_text(q, 8)
	case .File:
		m.file_name = db_col_text(q, 8)
		m.file_size = u64(db_col_int(q, 15))
	case .System:
		what, _ := strconv.parse_uint(db_col_text(q, 8))
		m.system = u8(what)
		m.system_arg = u32(db_col_int(q, 15))
	case .Image:
		m.image = {
			blob   = proto.Blob_Id(db_col_int(q, 9)),
			width  = u16(db_col_int(q, 10)),
			height = u16(db_col_int(q, 11)),
			size   = u32(db_col_int(q, 12)),
		}
	}
	return m
}
