package proto

import "core:encoding/endian"

/*
Messages: what is posted to a conversation (convs.odin), kept by the
server for good, and read a page at a time. Everything here travels as
requests and events (rpc.odin), except Typing, which is a datagram.

	Msg_Post     [conv u32][nonce u64][thread_root u64][kind u8]
	             text: [text str16][count u8][upload u64]... (attachments)
	             file: [size u64][name str8]
	             ->  [id u64][time u64]
	Msg_History  [conv u32][thread_root u64][anchor u64][dir u8][limit u8]
	             ->  [more u8][count u16] messages, oldest first
	Blob_Put     [kind u8][size u32][sha256 32][width u16][height u16]
	             ->  [blob u64][have u8][handle u64]
	Blob_Get     [blob u64]  ->  [size u32][handle u64]
	Msg_Edit     [id u64][text str16]
	Msg_Delete   [id u64]
	Msg_Pin      [id u64][on u8]
	Pins_Get     [conv u32]  ->  [count u16] messages, the newest pin first
	Msg_Forward  (forward.odin)
	Msg_React    [id u64][emoji str8][on u8]
	Reactors_Get [id u64][emoji str8]
	             ->  [total u16][count u8][account u32]...: who reacted
	             with that emoji, the earliest first, at most MAX_REACTORS
	             of the `total`

	Msg_New      a message, posted just now
	Msg_Changed  a message as it is now: edited, deleted, pinned or unpinned
	Reaction_Changed  [id u64][conv u32][emoji str8][count u16][account u32][on u8]:
	             `account` added (`on`) or took back a reaction; `count` is how
	             many have that one now

	message   [id u64][conv u32][sender u32][time u64][kind u8][flags u8]
	          [thread_root u64][edited u64]
	          text:    [text str16]
	                   if Has_Attachments: [count u8] per file:
	                   [blob u64][size u64][name str8]
	          file:    [size u64][name str8]
	          system:  [what u8][arg u32]
	          if Has_Thread: [reply_count u32][last_reply u64]
	          if Forwarded: [sender u32][conv u32][time u64] (forward.odin)
	          [reaction_count u8] per reaction: [emoji str8][count u16][me u8]

	client -> server  Typing  [kind][conv u32][thread_root u64]
	server -> client  Typing  [kind][conv u32][thread_root u64][account u32]

A message's id is the server's, global and increasing, so "newer than"
is one comparison. Its time is the server's clock, in milliseconds.

Posting: the nonce is the poster's own, chosen at random for each
message. A post repeated after the connection started over, with the
same nonce, is answered with the id the message got the first time and
isn't stored again.

History: a page of messages next to `anchor`: `Before` it (older; an
anchor of 0 means from the newest), `After` it, or `Around` it, the
anchor itself included. At most MAX_HISTORY_LIMIT; fewer if they
wouldn't fit in one stream message. `more` says whether the
conversation has messages beyond the page: older ones (MORE_BEFORE),
newer ones (MORE_AFTER).

Pictures (people's own, the server's emoji: profiles.odin, emoji.odin)
are blobs, stored once per content. The client announces one with
Blob_Put: if the server has that content already
(`have`), the answer is its id and nothing is sent; else the answer is
the handle to send the chunks under (blob.odin), and the server says
with Blob_Need when it has them all (BLOB_COMPLETE, then Blob_Put again
gives the id) or can't take them (BLOB_FAILED: the hash or the
picture's size wasn't what was announced). Blob_Get is the other way:
the size and the handle the chunks will come under.

Attachments: a text message may carry up to MAX_ATTACHMENTS files that
were uploaded to the server (attachments.odin), and then has the
Has_Attachments flag; its text may be empty then. A picture in a
message is one of these (a pasted one too). Posting names the
poster's uploads, and the server fills in each file's blob, name and
size from them. They go when the message is deleted.

Files: a message of kind File is an offer to send one, in a DM only; it
says the file's name and size, and the file itself goes between the two
clients when the offer is taken up (files.odin).

Editing, deleting, pinning: a text message may be edited by its author,
and then says when (`edited`); the old text isn't kept. A message may be
deleted by its author, or by an account with Manage_Messages: it stays,
with the Deleted flag, but its text and files are gone for good,
and it's no longer pinned. Pinning marks a message Pinned, for either
member of a DM and for those with Pin_Messages in a channel, at most
MAX_PINS in a conversation (Too_Large past that). Each change goes to
every connection of every member as Msg_Changed, the whole message as
it now is.

Reactions: a member reacts to a message with an emoji (emoji.odin): a
Unicode one's character, or `:name:` of one of the server's own; at most
MAX_REACTIONS different ones on a message, none on a deleted one. Each
account counts once per emoji. A message's record carries them, in the
order they were first given, with how many gave each and whether `me`
did: the one who asked, in a history page or Pins_Get; nobody in an
event (Msg_New, Msg_Changed), whose readers keep track of their own from
Reaction_Changed.

A thread root comes in a later phase; the record has room for it from
the start, and it's zero until then.
*/

MAX_CHAT_SIZE :: 2000 // bytes of UTF-8 in a message

// Unix_Time is seconds since the epoch, the server's clock: what the
// UI's clock shows a time to the minute in.
Unix_Time :: distinct u64

// Unix_Ms is milliseconds since the epoch, the server's clock.
Unix_Ms :: distinct u64

Msg_Id :: distinct u64
Blob_Id :: distinct u64

// 1 was a picture, which is an attachment now.
Msg_Kind :: enum u8 {
	Text   = 0,
	File   = 2,
	System = 3,
}

Msg_Flag :: enum u8 {
	Deleted,
	Pinned,
	Has_Thread,
	Forwarded, // a copy of another message (forward.odin)
	Has_Attachments, // files uploaded with it (attachments.odin)
}
Msg_Flags :: distinct bit_set[Msg_Flag;u8]

// What a blob is, which decides how big it may be.
Blob_Kind :: enum u8 {
	Avatar      = 2, // somebody's profile picture
	Emoji_Sheet = 3, // the server's custom emoji, as one image
	File        = 4, // a message's attachment (attachments.odin)
}

// The most files a message may carry.
MAX_ATTACHMENTS :: 10

// A file a message carries. The name points into what it was read from.
Attachment :: struct {
	blob: Blob_Id, // 0 once it's been removed (retention)
	size: u64,
	name: string,
}

// Message is one message. Strings point into what it was read from.
Message :: struct {
	id:               Msg_Id,
	conv:             Conv_Id,
	sender:           Account_Id,
	time:             Unix_Ms,
	kind:             Msg_Kind,
	flags:            Msg_Flags,
	thread_root:      Msg_Id,
	edited:           Unix_Ms,
	text:             string, // .Text
	file_size:        u64, // .File
	file_name:        string,
	system:           u8, // .System: what happened
	system_arg:       u32,
	reply_count:      u32, // .Has_Thread
	last_reply:       Msg_Id,
	forward:          Forward_Info, // .Forwarded: where the original was
	// .Has_Attachments: the files, the first `attachment_count`.
	attachment_count: int,
	attachments:      [MAX_ATTACHMENTS]Attachment,
	// The reactions, as they came, for when there are any.
	reaction_count:   int,
	reactions:        []u8,
}

// What a message's files take at most.
ATTACHMENTS_MAX_SIZE :: 1 + MAX_ATTACHMENTS * (8 + 8 + 1 + MAX_FILE_NAME)

// A message takes at most this much.
MESSAGE_MAX_SIZE ::
	8 +
	4 +
	4 +
	8 +
	1 +
	1 +
	8 +
	8 +
	(2 + MAX_CHAT_SIZE) +
	ATTACHMENTS_MAX_SIZE +
	4 +
	8 +
	FORWARD_INFO_SIZE +
	1 +
	MAX_REACTIONS * (1 + MAX_REACTION_EMOJI + 2 + 1)

MAX_HISTORY_LIMIT :: 50

// The most messages a conversation can have pinned.
MAX_PINS :: 50

// The most different emoji a message can be reacted to with, and the
// most bytes one of them takes (a server's own, written `:name:`).
MAX_REACTIONS :: 20
MAX_REACTION_EMOJI :: 2 + MAX_EMOJI_NAME

History_Dir :: enum u8 {
	Before = 0,
	After  = 1,
	Around = 2,
}

// A history page's `more`.
MORE_BEFORE :: 1 << 0
MORE_AFTER :: 1 << 1

MSG_HISTORY_SIZE :: 4 + 8 + 8 + 1 + 1
MSG_EDIT_MAX_SIZE :: 8 + 2 + MAX_CHAT_SIZE
MSG_ID_SIZE :: 8
MSG_PIN_SIZE :: 8 + 1
MSG_POSTED_SIZE :: 8 + 8
MSG_POST_MAX_SIZE :: 4 + 8 + 8 + 1 + max(2 + MAX_CHAT_SIZE + 1 + MAX_ATTACHMENTS * 8, 8 + 1 + 255)
HISTORY_HEADER_SIZE :: 1 + 2
BLOB_PUT_SIZE :: 1 + 4 + 32 + 2 + 2
BLOB_PUT_ANSWER_SIZE :: 8 + 1 + 8
BLOB_GET_SIZE :: 8
BLOB_GET_ANSWER_SIZE :: 4 + 8
TYPING_UP_SIZE :: 1 + 4 + 8
TYPING_DOWN_SIZE :: TYPING_UP_SIZE + 4

// message_size is how many bytes `m` takes as a record.
message_size :: proc(m: Message) -> int {
	n := 8 + 4 + 4 + 8 + 1 + 1 + 8 + 8
	switch m.kind {
	case .Text:
		n += 2 + len(m.text)
		if .Has_Attachments in m.flags {
			n += 1
			for i in 0 ..< m.attachment_count {
				a := m.attachments[i]
				n += 8 + 8 + 1 + len(a.name)
			}
		}
	case .File:
		n += 8 + 1 + len(m.file_name)
	case .System:
		n += 1 + 4
	}
	if .Has_Thread in m.flags {
		n += 4 + 8
	}
	if .Forwarded in m.flags {
		n += FORWARD_INFO_SIZE
	}
	return n + 1 + len(m.reactions)
}

@(private = "file")
put_message :: proc(w: ^Writer, m: Message) {
	put_u64(w, u64(m.id))
	put_u32(w, u32(m.conv))
	put_u32(w, u32(m.sender))
	put_u64(w, u64(m.time))
	put_u8(w, u8(m.kind))
	put_u8(w, transmute(u8)m.flags)
	put_u64(w, u64(m.thread_root))
	put_u64(w, u64(m.edited))
	switch m.kind {
	case .Text:
		if len(m.text) > MAX_CHAT_SIZE {
			w.overflow = true
		}
		put_str16(w, m.text)
		if .Has_Attachments in m.flags {
			if m.attachment_count < 1 || m.attachment_count > MAX_ATTACHMENTS {
				w.overflow = true
				return
			}
			put_u8(w, u8(m.attachment_count))
			for i in 0 ..< m.attachment_count {
				a := m.attachments[i]
				put_u64(w, u64(a.blob))
				put_u64(w, a.size)
				put_str8(w, a.name)
			}
		}
	case .File:
		put_u64(w, m.file_size)
		put_str8(w, m.file_name)
	case .System:
		put_u8(w, m.system)
		put_u32(w, m.system_arg)
	}
	if .Has_Thread in m.flags {
		put_u32(w, m.reply_count)
		put_u64(w, u64(m.last_reply))
	}
	if .Forwarded in m.flags {
		put_u32(w, u32(m.forward.sender))
		put_u32(w, u32(m.forward.conv))
		put_u64(w, u64(m.forward.time))
	}
	put_u8(w, u8(m.reaction_count))
	put_bytes(w, m.reactions)
}

@(private = "file")
get_message :: proc(r: ^Reader) -> (m: Message, ok: bool) {
	m.id = Msg_Id(get_u64(r))
	m.conv = Conv_Id(get_u32(r))
	m.sender = Account_Id(get_u32(r))
	m.time = Unix_Ms(get_u64(r))
	m.kind = Msg_Kind(get_u8(r))
	m.flags = transmute(Msg_Flags)get_u8(r)
	m.thread_root = Msg_Id(get_u64(r))
	m.edited = Unix_Ms(get_u64(r))
	switch m.kind {
	case .Text:
		m.text = get_str16(r)
		if len(m.text) > MAX_CHAT_SIZE {
			return
		}
		if .Has_Attachments in m.flags {
			m.attachment_count = int(get_u8(r))
			if m.attachment_count < 1 || m.attachment_count > MAX_ATTACHMENTS {
				return
			}
			for &a in m.attachments[:m.attachment_count] {
				a.blob = Blob_Id(get_u64(r))
				a.size = get_u64(r)
				a.name = get_str8(r)
			}
		}
	case .File:
		m.file_size = get_u64(r)
		m.file_name = get_str8(r)
	case .System:
		m.system = get_u8(r)
		m.system_arg = get_u32(r)
	case:
		return // a kind from a newer server: its layout isn't known
	}
	if .Has_Thread in m.flags {
		m.reply_count = get_u32(r)
		m.last_reply = Msg_Id(get_u64(r))
	}
	if .Forwarded in m.flags {
		m.forward = {
			sender = Account_Id(get_u32(r)),
			conv   = Conv_Id(get_u32(r)),
			time   = Unix_Ms(get_u64(r)),
		}
	}
	m.reaction_count = int(get_u8(r))
	start := r.pos
	for _ in 0 ..< m.reaction_count {
		_ = get_str8(r) // emoji
		_ = get_u16(r) // count
		_ = get_u8(r) // me
	}
	if r.overflow || m.id == 0 {
		return
	}
	m.reactions = r.buf[start:r.pos]
	return m, true
}

// encode_message writes one message, as in Msg_New; nil if it doesn't
// fit in `out`.
encode_message :: proc(out: []u8, m: Message) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_message(&w, m)
	return nil if w.overflow else out[:w.pos]
}

// decode_message reads one; its strings point into `body`.
decode_message :: proc(body: []u8) -> (m: Message, ok: bool) {
	r := Reader {
		buf = body,
	}
	m = get_message(&r) or_return
	return m, r.pos == len(body)
}

// Msg_Post is what posting a message says.
Msg_Post :: struct {
	conv:             Conv_Id,
	nonce:            u64,
	thread_root:      Msg_Id,
	kind:             Msg_Kind, // .Text or .File
	text:             string, // .Text, and .File's name; raw until sanitized
	file_size:        u64, // .File
	// .Text: the uploads of its files (Attach_Put), the first
	// `attachment_count`.
	attachment_count: int,
	uploads:          [MAX_ATTACHMENTS]u64,
}

encode_msg_post :: proc(out: []u8, p: Msg_Post) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(p.conv))
	put_u64(&w, p.nonce)
	put_u64(&w, u64(p.thread_root))
	put_u8(&w, u8(p.kind))
	#partial switch p.kind {
	case .Text:
		put_str16(&w, p.text)
		if p.attachment_count < 0 || p.attachment_count > MAX_ATTACHMENTS {
			return nil
		}
		put_u8(&w, u8(p.attachment_count))
		for i in 0 ..< p.attachment_count {
			put_u64(&w, p.uploads[i])
		}
	case .File:
		put_u64(&w, p.file_size)
		put_str8(&w, p.text)
	case:
		return nil
	}
	return nil if w.overflow else out[:w.pos]
}

decode_msg_post :: proc(body: []u8) -> (p: Msg_Post, ok: bool) {
	r := Reader {
		buf = body,
	}
	p.conv = Conv_Id(get_u32(&r))
	p.nonce = get_u64(&r)
	p.thread_root = Msg_Id(get_u64(&r))
	p.kind = Msg_Kind(get_u8(&r))
	#partial switch p.kind {
	case .Text:
		p.text = get_str16(&r)
		if len(p.text) > MAX_CHAT_SIZE {
			return
		}
		p.attachment_count = int(get_u8(&r))
		if p.attachment_count > MAX_ATTACHMENTS {
			return
		}
		for &upload in p.uploads[:p.attachment_count] {
			upload = get_u64(&r)
		}
	case .File:
		p.file_size = get_u64(&r)
		p.text = get_str8(&r)
	case:
		return
	}
	return p, !r.overflow && r.pos == len(body)
}

encode_msg_posted :: proc(out: ^[MSG_POSTED_SIZE]u8, id: Msg_Id, time: Unix_Ms) -> []u8 {
	endian.unchecked_put_u64le(out[0:], u64(id))
	endian.unchecked_put_u64le(out[8:], u64(time))
	return out[:]
}

decode_msg_posted :: proc(body: []u8) -> (id: Msg_Id, time: Unix_Ms, ok: bool) {
	if len(body) != MSG_POSTED_SIZE {
		return
	}
	id = Msg_Id(endian.unchecked_get_u64le(body[0:]))
	time = Unix_Ms(endian.unchecked_get_u64le(body[8:]))
	return id, time, id != 0
}

Msg_History :: struct {
	conv:        Conv_Id,
	thread_root: Msg_Id,
	anchor:      Msg_Id,
	dir:         History_Dir,
	limit:       int,
}

encode_msg_history :: proc(out: ^[MSG_HISTORY_SIZE]u8, h: Msg_History) -> []u8 {
	endian.unchecked_put_u32le(out[0:], u32(h.conv))
	endian.unchecked_put_u64le(out[4:], u64(h.thread_root))
	endian.unchecked_put_u64le(out[12:], u64(h.anchor))
	out[20] = u8(h.dir)
	out[21] = u8(clamp(h.limit, 0, MAX_HISTORY_LIMIT))
	return out[:]
}

decode_msg_history :: proc(body: []u8) -> (h: Msg_History, ok: bool) {
	if len(body) != MSG_HISTORY_SIZE || body[20] > u8(max(History_Dir)) {
		return
	}
	h = {
		conv        = Conv_Id(endian.unchecked_get_u32le(body[0:])),
		thread_root = Msg_Id(endian.unchecked_get_u64le(body[4:])),
		anchor      = Msg_Id(endian.unchecked_get_u64le(body[12:])),
		dir         = History_Dir(body[20]),
		limit       = int(body[21]),
	}
	return h, h.limit > 0 && h.limit <= MAX_HISTORY_LIMIT
}

// encode_history_page writes a Msg_History response: `msgs`, oldest
// first, or as many of them from the start as fit in `out`; `count` says
// how many. Whoever cuts a page short says so in `more`.
encode_history_page :: proc(out: []u8, more: u8, msgs: []Message) -> (body: []u8, count: int) {
	w := Writer {
		buf = out,
	}
	put_u8(&w, more)
	put_u16(&w, 0)
	for m in msgs {
		if w.pos + message_size(m) > len(out) || count == int(max(u16)) {
			break
		}
		put_message(&w, m)
		count += 1
	}
	if w.overflow {
		return nil, 0
	}
	endian.unchecked_put_u16le(out[1:], u16(count))
	return out[:w.pos], count
}

// decode_history_page reads one into `buf`.
decode_history_page :: proc(body: []u8, buf: []Message) -> (more: u8, msgs: []Message, ok: bool) {
	r := Reader {
		buf = body,
	}
	more = get_u8(&r)
	count := int(get_u16(&r))
	if r.overflow || count > len(buf) {
		return
	}
	for i in 0 ..< count {
		buf[i] = get_message(&r) or_return
	}
	if r.pos != len(body) {
		return
	}
	return more, buf[:count], true
}

Blob_Put :: struct {
	kind:          Blob_Kind,
	size:          int,
	hash:          [32]u8, // SHA-256
	width, height: int, // a picture's
}

encode_blob_put :: proc(out: ^[BLOB_PUT_SIZE]u8, p: Blob_Put) -> []u8 {
	p := p
	out[0] = u8(p.kind)
	endian.unchecked_put_u32le(out[1:], u32(p.size))
	copy(out[5:37], p.hash[:])
	endian.unchecked_put_u16le(out[37:], u16(p.width))
	endian.unchecked_put_u16le(out[39:], u16(p.height))
	return out[:]
}

decode_blob_put :: proc(body: []u8) -> (p: Blob_Put, ok: bool) {
	if len(body) != BLOB_PUT_SIZE {
		return
	}
	p.kind = Blob_Kind(body[0])
	p.size = int(endian.unchecked_get_u32le(body[1:]))
	copy(p.hash[:], body[5:37])
	p.width = int(endian.unchecked_get_u16le(body[37:]))
	p.height = int(endian.unchecked_get_u16le(body[39:]))
	return p, true
}

// encode_blob_put_answer: the blob's id if the server has it (`have`),
// else the handle its chunks go under.
encode_blob_put_answer :: proc(
	out: ^[BLOB_PUT_ANSWER_SIZE]u8,
	blob: Blob_Id,
	have: bool,
	handle: u64,
) -> []u8 {
	endian.unchecked_put_u64le(out[0:], u64(blob))
	out[8] = u8(have)
	endian.unchecked_put_u64le(out[9:], handle)
	return out[:]
}

decode_blob_put_answer :: proc(body: []u8) -> (blob: Blob_Id, have: bool, handle: u64, ok: bool) {
	if len(body) != BLOB_PUT_ANSWER_SIZE {
		return
	}
	blob = Blob_Id(endian.unchecked_get_u64le(body[0:]))
	have = body[8] != 0
	handle = endian.unchecked_get_u64le(body[9:])
	return blob, have, handle, have ? blob != 0 : handle != 0
}

encode_blob_id :: proc(out: ^[BLOB_GET_SIZE]u8, blob: Blob_Id) -> []u8 {
	endian.unchecked_put_u64le(out[:], u64(blob))
	return out[:]
}

decode_blob_id :: proc(body: []u8) -> (blob: Blob_Id, ok: bool) {
	if len(body) != BLOB_GET_SIZE {
		return
	}
	blob = Blob_Id(endian.unchecked_get_u64le(body))
	return blob, blob != 0
}

encode_blob_get_answer :: proc(out: ^[BLOB_GET_ANSWER_SIZE]u8, size: int, handle: u64) -> []u8 {
	endian.unchecked_put_u32le(out[0:], u32(size))
	endian.unchecked_put_u64le(out[4:], handle)
	return out[:]
}

decode_blob_get_answer :: proc(body: []u8) -> (size: int, handle: u64, ok: bool) {
	if len(body) != BLOB_GET_ANSWER_SIZE {
		return
	}
	size = int(endian.unchecked_get_u32le(body[0:]))
	handle = endian.unchecked_get_u64le(body[4:])
	return size, handle, size > 0 && size <= MAX_BLOB_SIZE && handle != 0
}

encode_typing_up :: proc(out: ^[TYPING_UP_SIZE]u8, conv: Conv_Id, thread_root: Msg_Id) -> []u8 {
	out[0] = u8(Message_Kind.Typing)
	endian.unchecked_put_u32le(out[1:], u32(conv))
	endian.unchecked_put_u64le(out[5:], u64(thread_root))
	return out[:]
}

decode_typing_up :: proc(pt: []u8) -> (conv: Conv_Id, thread_root: Msg_Id) {
	return Conv_Id(endian.unchecked_get_u32le(pt[1:])), Msg_Id(endian.unchecked_get_u64le(pt[5:]))
}

encode_typing_down :: proc(
	out: ^[TYPING_DOWN_SIZE]u8,
	conv: Conv_Id,
	thread_root: Msg_Id,
	account: Account_Id,
) -> []u8 {
	out[0] = u8(Message_Kind.Typing)
	endian.unchecked_put_u32le(out[1:], u32(conv))
	endian.unchecked_put_u64le(out[5:], u64(thread_root))
	endian.unchecked_put_u32le(out[13:], u32(account))
	return out[:]
}

decode_typing_down :: proc(pt: []u8) -> (conv: Conv_Id, thread_root: Msg_Id, account: Account_Id) {
	return Conv_Id(
		endian.unchecked_get_u32le(pt[1:]),
	), Msg_Id(endian.unchecked_get_u64le(pt[5:])), Account_Id(endian.unchecked_get_u32le(pt[13:]))
}

encode_msg_edit :: proc(out: ^[MSG_EDIT_MAX_SIZE]u8, id: Msg_Id, text: string) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u64(&w, u64(id))
	put_str16(&w, text)
	return nil if w.overflow else out[:w.pos]
}

// decode_msg_edit's text is raw, to be sanitized.
decode_msg_edit :: proc(body: []u8) -> (id: Msg_Id, text: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	id = Msg_Id(get_u64(&r))
	text = get_str16(&r)
	return id, text, !r.overflow && r.pos == len(body) && len(text) <= MAX_CHAT_SIZE
}

// A body that is one message's id: Msg_Delete.
encode_msg_id :: proc(out: ^[MSG_ID_SIZE]u8, id: Msg_Id) -> []u8 {
	endian.unchecked_put_u64le(out[:], u64(id))
	return out[:]
}

decode_msg_id :: proc(body: []u8) -> (id: Msg_Id, ok: bool) {
	if len(body) != MSG_ID_SIZE {
		return
	}
	id = Msg_Id(endian.unchecked_get_u64le(body))
	return id, id != 0
}

encode_msg_pin :: proc(out: ^[MSG_PIN_SIZE]u8, id: Msg_Id, on: bool) -> []u8 {
	endian.unchecked_put_u64le(out[:], u64(id))
	out[8] = u8(on)
	return out[:]
}

decode_msg_pin :: proc(body: []u8) -> (id: Msg_Id, on: bool, ok: bool) {
	if len(body) != MSG_PIN_SIZE {
		return
	}
	id = Msg_Id(endian.unchecked_get_u64le(body))
	return id, body[8] != 0, id != 0
}

// encode_message_list writes a Pins_Get response: as many of `msgs` as
// fit in `out`.
encode_message_list :: proc(out: []u8, msgs: []Message) -> []u8 {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	count := 0
	for m in msgs {
		if w.pos + message_size(m) > len(out) || count == int(max(u16)) {
			break
		}
		put_message(&w, m)
		count += 1
	}
	if w.overflow {
		return nil
	}
	endian.unchecked_put_u16le(out[0:], u16(count))
	return out[:w.pos]
}

// decode_message_list reads one into `buf`; the strings point into `body`.
decode_message_list :: proc(body: []u8, buf: []Message) -> (msgs: []Message, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(buf) {
		return
	}
	for i in 0 ..< count {
		buf[i] = get_message(&r) or_return
	}
	if r.pos != len(body) {
		return
	}
	return buf[:count], true
}

// Reaction is one emoji a message has been reacted to with.
Reaction :: struct {
	emoji: string,
	count: int,
	me:    bool,
}

MSG_REACT_MAX_SIZE :: 8 + 1 + MAX_REACTION_EMOJI + 1
REACTION_CHANGED_MAX_SIZE :: 8 + 4 + 1 + MAX_REACTION_EMOJI + 2 + 4 + 1

// set_reactions puts reactions in a message's record (at most
// MAX_REACTIONS); what it writes is in the temp allocator.
set_reactions :: proc(m: ^Message, reactions: []Reaction) {
	n := min(len(reactions), MAX_REACTIONS)
	out := make([]u8, n * (1 + MAX_REACTION_EMOJI + 3), context.temp_allocator)
	w := Writer {
		buf = out,
	}
	for r in reactions[:n] {
		put_str8(&w, r.emoji)
		put_u16(&w, u16(min(r.count, int(max(u16)))))
		put_u8(&w, u8(r.me))
	}
	m.reaction_count, m.reactions = n, out[:w.pos]
}

// reactions_of reads a message's reactions into `buf`; their emoji point
// into the message.
reactions_of :: proc(m: Message, buf: []Reaction) -> []Reaction {
	r := Reader {
		buf = m.reactions,
	}
	n := min(m.reaction_count, len(buf))
	for &x in buf[:n] {
		x.emoji = get_str8(&r)
		x.count = int(get_u16(&r))
		x.me = get_u8(&r) != 0
	}
	if r.overflow {
		return nil
	}
	return buf[:n]
}

encode_msg_react :: proc(
	out: ^[MSG_REACT_MAX_SIZE]u8,
	id: Msg_Id,
	emoji: string,
	on: bool,
) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u64(&w, u64(id))
	put_str8(&w, emoji)
	put_u8(&w, u8(on))
	return nil if w.overflow else out[:w.pos]
}

// The most accounts a Reactors_Get answer names.
MAX_REACTORS :: 50
REACTORS_GET_MAX_SIZE :: 8 + 1 + MAX_REACTION_EMOJI
REACTORS_MAX_SIZE :: 2 + 1 + 4 * MAX_REACTORS

encode_reactors_get :: proc(out: ^[REACTORS_GET_MAX_SIZE]u8, id: Msg_Id, emoji: string) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u64(&w, u64(id))
	put_str8(&w, emoji)
	return nil if w.overflow else out[:w.pos]
}

decode_reactors_get :: proc(body: []u8) -> (id: Msg_Id, emoji: string, ok: bool) {
	r := Reader {
		buf = body,
	}
	id = Msg_Id(get_u64(&r))
	emoji = get_str8(&r)
	return id, emoji, !r.overflow && id != 0 && len(emoji) > 0 && len(emoji) <= MAX_REACTION_EMOJI
}

// encode_reactors writes a Reactors_Get answer: how many reacted, and
// the first MAX_REACTORS of them.
encode_reactors :: proc(out: ^[REACTORS_MAX_SIZE]u8, total: int, accounts: []Account_Id) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	n := min(len(accounts), MAX_REACTORS)
	put_u16(&w, u16(min(total, int(max(u16)))))
	put_u8(&w, u8(n))
	for a in accounts[:n] {
		put_u32(&w, u32(a))
	}
	return out[:w.pos]
}

// decode_reactors reads a Reactors_Get answer, the accounts into `buf`.
decode_reactors :: proc(
	body: []u8,
	buf: ^[MAX_REACTORS]Account_Id,
) -> (
	total: int,
	accounts: []Account_Id,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	total = int(get_u16(&r))
	n := int(get_u8(&r))
	if n > MAX_REACTORS {
		return
	}
	for i in 0 ..< n {
		buf[i] = Account_Id(get_u32(&r))
	}
	return total, buf[:n], !r.overflow
}

decode_msg_react :: proc(body: []u8) -> (id: Msg_Id, emoji: string, on: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	id = Msg_Id(get_u64(&r))
	emoji = get_str8(&r)
	on = get_u8(&r) != 0
	return id,
		emoji,
		on,
		!r.overflow && id != 0 && len(emoji) > 0 && len(emoji) <= MAX_REACTION_EMOJI
}

Reaction_Change :: struct {
	id:      Msg_Id,
	conv:    Conv_Id,
	emoji:   string,
	count:   int,
	account: Account_Id,
	on:      bool,
}

encode_reaction_changed :: proc(out: ^[REACTION_CHANGED_MAX_SIZE]u8, c: Reaction_Change) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u64(&w, u64(c.id))
	put_u32(&w, u32(c.conv))
	put_str8(&w, c.emoji)
	put_u16(&w, u16(min(c.count, int(max(u16)))))
	put_u32(&w, u32(c.account))
	put_u8(&w, u8(c.on))
	return nil if w.overflow else out[:w.pos]
}

decode_reaction_changed :: proc(body: []u8) -> (c: Reaction_Change, ok: bool) {
	r := Reader {
		buf = body,
	}
	c.id = Msg_Id(get_u64(&r))
	c.conv = Conv_Id(get_u32(&r))
	c.emoji = get_str8(&r)
	c.count = int(get_u16(&r))
	c.account = Account_Id(get_u32(&r))
	c.on = get_u8(&r) != 0
	return c, !r.overflow
}
