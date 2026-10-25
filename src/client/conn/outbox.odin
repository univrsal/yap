package conn

import log "common:wlog"
import "core:crypto"
import "core:strings"

import "common:proto"

// The outbox: the messages of ours that are on their way.
//
// What we post goes into the outbox, one message at a time in the order they
// were written. A message's files are uploaded first (see attachments.odin)
// and then the message is posted. Each message has a nonce, and a post that was lost with
// the connection is repeated with the same nonce, which the server recognizes.
// What is written to somebody we have no DM with yet waits in the outbox while
// the server opens one (DM_Open, see buddies.odin). An offer of a file is posted
// the same way, and its transfer starts once the offer has its id (see
// files.odin).

Post_State :: enum {
	Open, // the DM it is for has to be opened (DM_Open)
	Post, // the message has to be posted
}

// Pending is a message of ours that is on its way.
Pending :: struct {
	nonce:  u64,
	conv:   proto.Conv_Id, // 0 while its DM is being opened
	root:   proto.Msg_Id, // the thread it replies in, if it is a reply
	dm_to:  proto.Account_Id, // who it is for, if it is a DM
	kind:   proto.Msg_Kind,
	text:   string, // .Text; for .File its name; owned
	size:   u64, // for .File
	state:  Post_State,
	asking: bool, // a request for it is pending
	// A message with files (see attachments.odin), which names the uploads.
	attach: ^Attach_Post,
}

// Posts a message to the conversation we are looking at. With `dm_to` it is
// posted to the DM with that account, and with `thread` it is posted as a reply
// in that thread.
Chat_Command :: struct {
	text:   string, // owned by the command
	dm_to:  proto.Account_Id,
	thread: Timeline_Key,
	// The text is as typed, with `@username` for a mention, instead of as
	// stored (headless; the UI turns it into tokens itself).
	typed:  bool,
}

pending_destroy :: proc(p: ^Pending) {
	delete(p.text)
	p^ = {}
}

// chat_send puts a message in the outbox. It is for the conversation we are
// looking at, or with `dm_to`, for the DM with that account, or with `thread`,
// a reply in that thread.
chat_send :: proc(
	c: ^Server_Conn,
	raw: string,
	dm_to: proto.Account_Id = 0,
	thread := Timeline_Key{},
) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	conv, state, ok := post_target(c, dm_to)
	thread := thread
	if thread.root != 0 {
		conv, state, ok = thread.conv, .Post, thread.conv in c.convs.convs
		// The server treats a reply to a reply as a reply to the root, so
		// our pending copy has to point at the root too.
		if m, found := msg_find(c, thread.conv, thread.root); found && m.thread_root != 0 {
			thread.root = m.thread_root
		}
	}
	if text == "" || !ok {
		return
	}
	append(
		&c.msgs.outbox,
		Pending {
			nonce = new_nonce(),
			conv = conv,
			root = thread.root,
			dm_to = dm_to,
			kind = .Text,
			text = strings.clone(text),
			state = state,
		},
	)
	// Any typing after this starts a new typing notice.
	c.msgs.last_typing = {}
	to_the_end(c, {conv, thread.root})
	publish_outbox(c)
}

// post_target returns where a post goes: the conversation we are looking at,
// or with `dm_to`, the DM with that account, which may have to be opened first.
// `first` is the state the post starts in if nothing has to be opened. It
// returns false if there is nowhere to post.
post_target :: proc(
	c: ^Server_Conn,
	dm_to: proto.Account_Id,
	first := Post_State.Post,
) -> (
	conv: proto.Conv_Id,
	state: Post_State,
	ok: bool,
) {
	if dm_to == 0 {
		conv = c.convs.viewing
		return conv, first, conv != 0
	}
	if dm_to == c.auth.me {
		return
	}
	conv = dm_with(c, dm_to)
	return conv, first if conv != 0 else .Open, true
}

// file_post puts the offer of a file in the outbox, for the DM with `to`. It
// returns the offer's nonce, by which files.odin identifies the transfer until
// the offer has an id.
file_post :: proc(c: ^Server_Conn, to: proto.Account_Id, name: string, size: u64) -> u64 {
	conv, state, _ := post_target(c, to)
	p := Pending {
		nonce = new_nonce(),
		conv  = conv,
		dm_to = to,
		kind  = .File,
		text  = strings.clone(name),
		size  = size,
		state = state,
	}
	append(&c.msgs.outbox, p)
	to_the_end(c, {conv, 0})
	publish_outbox(c)
	return p.nonce
}

new_nonce :: proc() -> (nonce: u64) {
	for nonce == 0 {
		crypto.rand_bytes(([^]u8)(&nonce)[:size_of(nonce)])
	}
	return
}

// drive_outbox advances the oldest entry in our outbox: a message is posted
// once its DM is open and its files are uploaded. Entries are sent one at a
// time, so that they arrive in the order they were written.
drive_outbox :: proc(c: ^Server_Conn) {
	mc := &c.msgs
	if len(mc.outbox) == 0 || !c.has_current || !c.convs.synced {
		return
	}
	p := &mc.outbox[0]
	if p.state != .Open && p.conv not_in c.convs.convs {
		log.warn("a message wasn't posted because we are no longer a member of its channel")
		outbox_fail(c)
		return
	}
	switch p.state {
	case .Open:
		if conv := dm_with(c, p.dm_to); conv != 0 {
			// The DM has been opened since, by this post's DM_Open or
			// otherwise.
			p.conv = conv
			p.state = .Post
			p.asking = false
			to_the_end(c, {conv, 0})
			publish_outbox(c)
		} else if !p.asking {
			p.asking = true
			buf: [4]u8
			request(c, .DM_Open, proto.encode_account_id(&buf, p.dm_to), open_done, p.nonce)
		}
	case .Post:
		if !p.asking {
			p.asking = true
			buf: [proto.MSG_POST_MAX_SIZE]u8
			post := proto.Msg_Post {
				conv        = p.conv,
				nonce       = p.nonce,
				thread_root = p.root,
				kind        = p.kind,
				text        = p.text,
				file_size   = p.size,
			}
			if p.attach != nil {
				post.attachment_count = len(p.attach.files)
				for f, i in p.attach.files {
					post.uploads[i] = f.id
				}
			}
			request(c, .Msg_Post, proto.encode_msg_post(buf[:], post), post_done, p.nonce)
		}
	}
}

// outbox_head returns the message at the head of the outbox if it is the one
// with `nonce`, and nil otherwise.
outbox_head :: proc(c: ^Server_Conn, nonce: u64) -> ^Pending {
	if len(c.msgs.outbox) == 0 || c.msgs.outbox[0].nonce != nonce {
		return nil
	}
	return &c.msgs.outbox[0]
}

// outbox_pop drops the message at the head of the outbox, which is done with.
outbox_pop :: proc(c: ^Server_Conn) {
	pending_destroy(&c.msgs.outbox[0])
	ordered_remove(&c.msgs.outbox, 0)
	publish_outbox(c)
}

// outbox_fail drops the message at the head of the outbox, which could not be
// posted, and tells what was waiting for it.
outbox_fail :: proc(c: ^Server_Conn) {
	p := &c.msgs.outbox[0]
	if p.kind == .File {
		file_post_failed(c, p.nonce)
	}
	if p.attach != nil {
		attach_post_failed(c, p.attach)
	}
	outbox_pop(c)
}

// outbox_give_up is outbox_fail, with a notice of why.
outbox_give_up :: proc(c: ^Server_Conn, why: string) {
	notify(c, false, why)
	outbox_fail(c)
}

// open_done handles the answer to opening the DM that a post is for. The server
// tells us about the DM (Conv_Changed) before answering, so we already know it
// by now.
@(private = "file")
open_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	p := outbox_head(c, tag)
	if p == nil || p.state != .Open {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // asked again on the new connection
	case:
		outbox_give_up(c, "A message wasn't sent because the server failed to open the DM.")
		return
	}
	conv, ok := proto.decode_conv_id(body)
	if !ok || conv not_in c.convs.convs {
		return // asked for again by drive_outbox
	}
	p.conv = conv
	p.state = .Post
	to_the_end(c, {conv, 0})
	if c.view == nil && c.convs.viewing != conv {
		// Headless: /say posts to this DM from now on.
		conv_view(c, conv)
	}
	publish_outbox(c)
}

@(private = "file")
post_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	p := outbox_head(c, tag)
	if p == nil {
		return
	}
	p.asking = false
	#partial switch status {
	case .Ok:
	case .Reset:
		return // posted again, with the same nonce, on the new connection
	case .Not_Found:
		if p.attach != nil && p.state == .Post {
			// It's its uploaded files that are gone: they are uploaded
			// again, and the message is queued again after that.
			attach_upload_again(c, p.attach)
			outbox_pop(c)
			return
		}
		outbox_give_up(c, "A message wasn't posted because its channel no longer exists.")
		return
	case .Invalid:
		if p.kind == .File {
			outbox_give_up(
				c,
				"That file can't be offered: only archives, pictures and videos are allowed.",
			)
			return
		}
		if p.root != 0 {
			outbox_give_up(
				c,
				"A reply wasn't posted because the message it replies to no longer exists.",
			)
			return
		}
		outbox_give_up(c, "A message wasn't posted because the server rejected it as invalid.")
		return
	case .Denied:
		outbox_give_up(c, "A message wasn't posted because you can't write or attach files there.")
		return
	case:
		outbox_give_up(c, "A message wasn't posted because the server rejected it.")
		return
	}
	id, at, ok := proto.decode_msg_posted(body)
	if !ok {
		return
	}
	if p.attach != nil {
		// The message arrives next as Msg_New, along with its files' blobs.
		attach_posted(c, p.attach)
		outbox_pop(c)
		return
	}
	m := proto.Message {
		id          = id,
		conv        = p.conv,
		sender      = c.auth.me,
		time        = at,
		kind        = p.kind,
		thread_root = p.root,
		text        = p.text,
	}
	if p.kind == .File {
		m.text, m.file_name, m.file_size = "", p.text, p.size
		file_posted(c, p.nonce, id)
	}
	message_arrived(c, m)
	outbox_pop(c)
}
