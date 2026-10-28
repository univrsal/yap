package server

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

// Messages (see src/common/proto/messages.odin) are posted to a conversation,
// stored permanently in the database and read back one page at a time.
//
// Only the members of a conversation can post to it and read it. A posted
// message is sent immediately as Msg_New to every connection of every
// member, including the poster's own connections. The poster's other
// devices need it too, and the connection that posted it matches it to what
// it sent using the id in the answer. Messages are never replayed later. A
// client that was away asks for what it missed (Msg_History).
//
// A post contains a nonce chosen by the poster. The database stores it. If
// a post arrives again with the same nonce (because the client repeated it
// after its connection started over), the answer is the message that was
// already posted.
//
// A text message may carry files that were uploaded for it (see
// attachments.odin). The post refers to them by their uploads. A picture in
// a message is one of these files.
// A file is offered in a DM by a message that contains its name and size.
// The file itself is transferred between the two clients (see files.odin).
//
// The first message in a DM is how the other account learns about it. Its
// connections are told about the conversation (Conv_Changed) just before
// the message arrives.

// Typing notices from one connection are forwarded at most this often.
TYPING_RELAY_INTERVAL :: 500 * time.Millisecond

// message_request handles a request about messages or blobs. Returns false
// if `op` isn't one.
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
	case .Bookmark_Set:
		bookmark_set(s, u, id, body)
	case .Bookmarks_Get:
		bookmarks_get(s, u, id, body)
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

// conv_of_member returns the conversation `conv_id` if the connection's
// account is a member of it. Otherwise it returns the status that explains why not.
conv_of_member :: proc(s: ^Server, u: ^Conn, conv_id: proto.Conv_Id) -> (^Conv, proto.Status) {
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil || !conv_visible(conv, u.account) {
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
	// A nonce of 0 can't be used to detect a repeated post.
	if !ok || p.nonce == 0 {
		respond(u, id, .Invalid)
		return
	}
	conv, status := conv_of_member(s, u, p.conv)
	if conv == nil {
		respond(u, id, status)
		return
	}
	rights := conv_rights(conv, u.account)
	if dm_closed(s, conv) ||
	   .Write not_in rights ||
	   (p.attachment_count > 0 && .Attach not_in rights) {
		respond(u, id, .Denied)
		return
	}
	root, root_ok := thread_root_of(s, conv, p.thread_root)
	if !root_ok {
		respond(u, id, .Invalid)
		return
	}
	if msg_repeated(s, u, id, p.nonce) {
		return
	}
	sender := u.account.id

	m := proto.Message {
		conv        = conv.id,
		sender      = sender,
		kind        = p.kind,
		thread_root = root.id,
	}
	text_buf := new([proto.MAX_CHAT_SIZE]u8, context.temp_allocator)
	name_buf: [proto.MAX_FILE_NAME]u8
	persona_buf: [proto.MAX_NAME_SIZE]u8
	mentioned: []proto.Account_Id
	#partial switch p.kind {
	case .File:
		// Files can only be offered in a DM with someone else, and only
		// allowed file types.
		m.file_name = proto.sanitize_file_name(p.text, &name_buf)
		m.file_size = p.file_size
		if conv.kind != .DM ||
		   conv.a == conv.b ||
		   m.file_size == 0 ||
		   m.file_size > proto.MAX_FILE_SIZE ||
		   m.file_name == "" ||
		   !proto.file_type_allowed(m.file_name) {
			respond(u, id, .Invalid)
			return
		}
	case .Text:
		m.text = proto.sanitize_message(p.text, text_buf[:])
		if p.persona.name != "" {
			persona, persona_status := persona_check(s, u.account, p.persona, &persona_buf)
			if persona_status != .Ok {
				respond(u, id, persona_status)
				return
			}
			m.persona = persona
			m.flags += {.Persona}
		}
		// The files that the message carries must be uploads of the poster,
		// and each upload may only be used once.
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
				blob   = up.blob,
				size   = up.size,
				name   = up.name,
				width  = up.width,
				height = up.height,
			}
		}
		m.attachment_count = p.attachment_count
		if m.attachment_count > 0 {
			m.flags += {.Has_Attachments}
		} else if m.text == "" {
			respond(u, id, .Invalid)
			return
		}
		// This happens before the message is stored. An account that gets
		// subscribed by being mentioned hasn't read the message yet.
		m.text, mentioned = mentions_resolve(
			s,
			u,
			conv,
			links_restrict(s, conv, m.text),
			conv.last_msg,
		)
		// Rewriting links and mentions can make the text longer. Text over
		// the limit wouldn't fit in the events and history pages that carry
		// the message, so it would break them for everyone.
		if len(m.text) > proto.MAX_CHAT_SIZE {
			respond(u, id, .Too_Large)
			return
		}
	}
	first := conv.last_msg == 0
	if !msg_store(s, conv, &m, p.nonce) || !mentions_store(s, conv, m.id, mentioned) {
		respond(u, id, .Internal)
		return
	}
	// The message content is only logged when debugging.
	place: string
	switch conv.kind {
	case .Channel:
		place = conv.name
	case .DM:
		place = fmt.tprintf("a DM with account %d", dm_other(conv, sender))
		if conv.a == conv.b {
			place = "a DM with oneself"
		}
	case .Group:
		place = fmt.tprintf("a group of accounts %v", conv.members[:])
	}
	#partial switch m.kind {
	case .Text:
		log.debugf("%s in %q: %s (%d files)", conn_label(u), place, m.text, m.attachment_count)
	case .File:
		log.debugf(
			"%s in %q: offers %q (%d bytes)",
			conn_label(u),
			place,
			m.file_name,
			m.file_size,
		)
		file_offered(s, u, conv, m)
	}
	msg_published(s, u, id, conv, m, root.id, first, mentioned)
}

// thread_root_of finds the root of the thread that a message replying to
// `reply_to` (0 for none) belongs to. It has to be a message of `conv` that
// isn't deleted, and a reply to a reply is added to the same thread, using
// the root of that reply. With no thread, `root` is zero and `ok` true.
@(private = "file")
thread_root_of :: proc(
	s: ^Server,
	conv: ^Conv,
	reply_to: proto.Msg_Id,
) -> (
	root: proto.Message,
	ok: bool,
) {
	if reply_to == 0 {
		return {}, true
	}
	found: bool
	root, found = msg_by_id(s, reply_to)
	if found && root.thread_root != 0 {
		root, found = msg_by_id(s, root.thread_root)
	}
	return root, found && root.conv == conv.id && .Deleted not_in root.flags
}

// msg_repeated answers a post (or forward) that was already made with this
// nonce, whose answer was lost together with the connection, and says
// whether it did.
@(private = "file")
msg_repeated :: proc(s: ^Server, u: ^Conn, id: u32, nonce: u64) -> bool {
	prev, at, found := msg_by_nonce(&s.db, u.account.id, nonce)
	if found {
		posted: [proto.MSG_POSTED_SIZE]u8
		respond(u, id, .Ok, proto.encode_msg_posted(&posted, prev, at))
	}
	return found
}

// msg_published answers a post or forward that was stored as `m`, and tells
// everyone concerned. `first` says whether it is the first message of the
// conversation, and `root` is its thread's root, 0 for none.
@(private = "file")
msg_published :: proc(
	s: ^Server,
	u: ^Conn,
	id: u32,
	conv: ^Conv,
	m: proto.Message,
	root: proto.Msg_Id,
	first: bool,
	mentioned: []proto.Account_Id,
) {
	posted: [proto.MSG_POSTED_SIZE]u8
	respond(u, id, .Ok, proto.encode_msg_posted(&posted, m.id, m.time))
	if first && conv.kind != .Channel {
		// The conversation is new to the other members of a DM or a group, so
		// they are told about the conversation before the message arrives.
		// They are told about the conversation as it was before the message,
		// so that the message then counts as unread like any other.
		last := conv.last_msg
		conv.last_msg = 0
		for other in conv.members {
			if other != u.account.id {
				send_conv_to_account(s, other, conv)
			}
		}
		conv.last_msg = last
	}
	msg_deliver(s, conv, m)
	push_message(s, conv, m, mentioned)
	if root != 0 {
		thread_changed(s, conv, root)
	}
	// The poster has read everything that came before the message.
	if conv_set_read(&s.convs, conv, u.account.id, m.id) {
		send_read(s, u.account, conv)
	}
}

// links_restrict keeps links to the messages of a DM or a group (see
// proto/forward.odin) inside it. Only its members could follow such a link
// anywhere else, so there it is replaced with plain text. The result is
// allocated with the temp allocator, or is `text` itself if nothing had to
// be changed.
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
		if l.conv == conv.id || linked == nil || linked.kind == .Channel {
			continue
		}
		plain := "(a message in a DM)" if linked.kind == .DM else "(a message in a group)"
		out = strings.concatenate({out[:l.start], plain, out[l.end:]}, context.temp_allocator)
		at = l.start + len(plain)
	}
}

// msg_forward copies a message that the account may read to a conversation
// that it may post to (see proto/forward.odin). The copy contains the
// content of the original and where it came from. A forward that is
// repeated with the same nonce is answered like a repeated post.
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
	if dm_closed(s, conv) || .Write not_in conv_rights(conv, u.account) {
		respond(u, id, .Denied)
		return
	}
	src, _, readable := msg_readable(s, u, f.msg)
	if !readable {
		respond(u, id, .Not_Found)
		return
	}
	if .Deleted in src.flags || src.kind != .Text {
		respond(u, id, .Invalid)
		return
	}
	// Its files come along, which takes the right to attach them there.
	if src.attachment_count > 0 && .Attach not_in conv_rights(conv, u.account) {
		respond(u, id, .Denied)
		return
	}
	// When forwarding into a thread, its root must belong to this
	// conversation, just like for a post.
	root, root_ok := thread_root_of(s, conv, f.thread_root)
	if !root_ok {
		respond(u, id, .Invalid)
		return
	}
	if msg_repeated(s, u, id, f.nonce) {
		return
	}
	// The original's author, conversation and time. If the message is itself
	// a copy, the details of its original are used.
	from := proto.Forward_Info{src.sender, src.conv, src.time}
	if .Forwarded in src.flags {
		from = src.forward
	}
	m := proto.Message {
		conv             = conv.id,
		sender           = u.account.id,
		kind             = src.kind,
		flags            = {.Forwarded},
		thread_root      = root.id,
		text             = links_restrict(s, conv, src.text),
		forward          = from,
		attachment_count = src.attachment_count,
		attachments      = src.attachments,
	}
	if .Has_Attachments in src.flags {
		m.flags += {.Has_Attachments}
	}
	if len(m.text) > proto.MAX_CHAT_SIZE {
		respond(u, id, .Too_Large) // see msg_post
		return
	}
	first := conv.last_msg == 0
	if !msg_store(s, conv, &m, f.nonce) {
		respond(u, id, .Internal)
		return
	}
	log.debugf("%s forwarded message %d to conversation %d", conn_label(u), src.id, conv.id)
	msg_published(s, u, id, conv, m, root.id, first, nil)
}

// msg_store adds a message to the database, filling in its id and time, and
// makes it the last message of its conversation. `m` must already contain
// the conversation, sender, kind and content.
msg_store :: proc(s: ^Server, conv: ^Conv, m: ^proto.Message, nonce: u64) -> bool {
	m.conv = conv.id
	m.time = proto.Unix_Ms(unix_ms())
	msg_insert(&s.db, m, nonce) or_return
	attachments_store(s, m^) or_return
	if conv.kind == .DM {
		conv.posted[0 if m.sender == conv.a else 1] = true
	}

	q := db_query(&s.db, .Conv_Set_Last, i64(conv.id), i64(m.id))
	db_run(&s.db, q) or_return
	conv.last_msg, conv.last_time = m.id, m.time
	return true
}

// msg_insert writes a message's row, filling in its id. The message keeps its
// time (msg_store sets it to now; the importer's messages have their own). It
// doesn't touch what depends on the message: its files, the conversation's last
// message, who has posted in a DM.
msg_insert :: proc(db: ^DB, m: ^proto.Message, nonce: u64) -> bool {
	q := db_query(db, .Msg_Add, i64(m.conv), i64(m.sender), i64(m.time), i64(m.kind))
	#partial switch m.kind {
	case .Text:
		db_bind_text(q, 5, m.text)
	case .File:
		db_bind_text(q, 5, m.file_name)
	case .System:
		// What happened, as a number, followed by its text on the next line
		// if it has one. Its argument is stored in the column that holds
		// the size of a file.
		if m.text != "" {
			db_bind_text(q, 5, fmt.tprintf("%d\n%s", m.system, m.text))
		} else {
			db_bind_text(q, 5, fmt.tprint(m.system))
		}
	case:
		db_bind_null(q, 5)
	}
	if nonce != 0 {
		db_bind_int(q, 6, i64(nonce))
	} else {
		db_bind_null(q, 6) // messages from the server itself are never repeated by a client
	}
	db_bind_int(q, 7, i64(m.system_arg) if m.kind == .System else i64(m.file_size))
	db_bind_int(q, 8, i64(m.thread_root))
	db_bind_int(q, 9, i64(transmute(u8)m.flags))
	db_bind_int(q, 10, i64(m.forward.sender))
	db_bind_int(q, 11, i64(m.forward.conv))
	db_bind_int(q, 12, i64(m.forward.time))
	if .Persona in m.flags {
		db_bind_text(q, 13, m.persona.name)
		if m.persona.avatar != 0 {
			db_bind_int(q, 14, i64(m.persona.avatar))
		} else {
			db_bind_null(q, 14)
		}
	} else {
		db_bind_null(q, 13)
		db_bind_null(q, 14)
	}
	db_bind_int(q, 15, i64(m.edited))
	db_run(db, q) or_return
	m.id = proto.Msg_Id(db_last_id(db))
	return true
}

// msg_by_nonce finds the message that `sender` posted with `nonce`, if there is one.
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
	q := db_query(db, .Msg_By_Nonce, i64(sender), i64(nonce))
	row, ok := db_step(db, q)
	if !ok || !row {
		return
	}
	id = proto.Msg_Id(db_col_int(q, 0))
	at = proto.Unix_Ms(db_col_int(q, 1))
	sqlite.reset(q)
	return id, at, true
}

// msg_deliver sends a message to every connection of every member of its
// conversation. It is either a new message or, if `op` is Msg_Changed, a
// message in its current state.
msg_deliver :: proc(s: ^Server, conv: ^Conv, m: proto.Message, op := proto.Event_Op.Msg_New) {
	buf := new([proto.MESSAGE_MAX_SIZE]u8, context.temp_allocator)
	body := proto.encode_message(buf[:], m)
	if body == nil {
		log.errorf("message %d doesn't fit in a record", m.id)
		return
	}
	for member in conv.members {
		acc := s.accounts.by_id[member] or_else nil
		if !conv_reader(conv, acc) {
			continue
		}
		for c in acc.conns {
			send_event(c, op, body)
		}
	}
}

// msg_history answers with a page of a conversation's messages, oldest
// first. See proto.History_Dir for which page is returned.
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
	// For the replies of a thread, the root must be a message of this
	// conversation.
	if h.thread_root != 0 {
		if root, found := msg_by_id(s, h.thread_root);
		   !found || root.conv != conv.id || root.thread_root != 0 {
			respond(u, id, .Not_Found)
			return
		}
	}
	msgs, more, read_ok := history_page(
		s,
		conv.id,
		h.anchor,
		h.dir,
		h.limit,
		u.account.id,
		h.thread_root,
	)
	if !read_ok {
		respond(u, id, .Internal)
		return
	}
	out := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	page, _ := proto.encode_history_page(out, more, msgs)
	respond(u, id, .Ok, page)
}

// history_page reads up to `limit` messages of a conversation next to
// `anchor`, oldest first, and reports whether there are more messages beyond
// them in either direction. The page is limited to what fits in one answer,
// and messages are dropped from the end that is furthest from the anchor.
// The strings of the messages are allocated with the temp allocator.
history_page :: proc(
	s: ^Server,
	conv: proto.Conv_Id,
	anchor: proto.Msg_Id,
	dir: proto.History_Dir,
	limit: int,
	asker: proto.Account_Id, // the account whose own reactions are marked
	thread_root: proto.Msg_Id = 0, // read the replies of a thread instead of the whole conversation
) -> (
	msgs: []proto.Message,
	more: u8,
	ok: bool,
) {
	list := make([dynamic]proto.Message, 0, limit + 2, context.temp_allocator)
	// Use the statements for either a thread or the whole conversation.
	thread := thread_root != 0
	before := Stmt.Thread_Before if thread else .Msg_Before
	after := Stmt.Thread_After if thread else .Msg_After
	any_before := Stmt.Thread_Any_Before if thread else .Msg_Any_Before
	any_after := Stmt.Thread_Any_After if thread else .Msg_Any_After
	// For a thread, the statements are given the root instead of the
	// conversation.
	scope := proto.Conv_Id(thread_root) if thread else conv
	switch dir {
	case .Before:
		// Read newest first, and one more than requested to find out whether
		// there are more.
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
		// First read the anchor and the older half, then the newer half.
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
	// A page of long messages (with files and reactions) can be too big for
	// one answer. In that case the messages furthest from the anchor are dropped.
	msgs = list[:]
	size := proto.HISTORY_HEADER_SIZE
	for m in msgs {
		size += proto.message_size(m)
	}
	// For Around, find where the anchor is in the page so that the page stays centered on it.
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

// msgs_read appends up to `limit` messages read with one of the history
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
	q := db_query(&s.db, stmt, i64(conv), anchor, i64(limit))
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

// msg_any returns whether one of the statements that look for a message
// before or after an id finds one.
@(private = "file")
msg_any :: proc(s: ^Server, stmt: Stmt, conv: proto.Conv_Id, id: proto.Msg_Id) -> bool {
	q := db_query(&s.db, stmt, i64(conv), i64(id))
	row, ok := db_step(&s.db, q)
	if ok && row {
		sqlite.reset(q)
		return true
	}
	return false
}

// handle_typing tells the other members of a conversation that are
// connected that someone is typing in it.
handle_typing :: proc(s: ^Server, from: ^Conn, pt: []u8) {
	now := time.tick_now()
	if from.last_typing != {} && time.tick_diff(from.last_typing, now) < TYPING_RELAY_INTERVAL {
		return
	}
	conv_id, root := proto.decode_typing_up(pt)
	conv := conv_by_id(&s.convs, conv_id)
	if conv == nil ||
	   !conv_is_member(conv, from.account.id) ||
	   .Write not_in conv_rights(conv, from.account) ||
	   dm_closed(s, conv) {
		return
	}
	from.last_typing = now

	buf: [proto.TYPING_DOWN_SIZE]u8
	msg := proto.encode_typing_down(&buf, conv_id, root, from.account.id)
	for member in conv.members {
		acc := s.accounts.by_id[member] or_else nil
		if acc == nil || acc == from.account || !conv_reader(conv, acc) {
			continue
		}
		for u in acc.conns {
			if c := sending_session(s, u); c != nil {
				send_message(s, c, msg)
			}
		}
	}
}

// msg_of_row converts the current row of one of the statements that read
// whole messages to a message. Its strings are allocated with the temp allocator.
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
		reply_count = u32(db_col_int(q, 9)),
		last_reply  = proto.Msg_Id(db_col_int(q, 10)),
	}
	if .Forwarded in m.flags {
		m.forward = {
			sender = proto.Account_Id(db_col_int(q, 12)),
			conv   = proto.Conv_Id(db_col_int(q, 13)),
			time   = proto.Unix_Ms(db_col_int(q, 14)),
		}
	}
	if .Persona in m.flags {
		m.persona = {
			name   = db_col_text(q, 15),
			avatar = proto.Blob_Id(db_col_int(q, 16)),
		}
	}
	#partial switch m.kind {
	case .Text:
		m.text = db_col_text(q, 8)
	case .File:
		m.file_name = db_col_text(q, 8)
		m.file_size = u64(db_col_int(q, 11))
	case .System:
		number, _, text := strings.partition(db_col_text(q, 8), "\n")
		what, _ := strconv.parse_uint(number)
		m.system = u8(what)
		m.system_arg = u32(db_col_int(q, 11))
		m.text = text
	}
	return m
}
