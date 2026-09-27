package client

import log "../common/wlog"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

import "../common"
import "../proto"

/*
Direct messages (see src/proto/dm.odin for the protocol): our end of
them, and the history of each conversation. Images in them are in
dm_images.odin.

Sending works like the channel's chat: one message at a time, resent
until the server takes it (DM_Sent), after which it's Sent, and
Delivered if the server later tells us the recipient has it. A DM the
server refuses, or one still unconfirmed when the client stopped, is
Failed.

A conversation's history is kept in the store next to our key, as
dms/<their key>.json, the last DM_HISTORY messages of it, with
dms/index listing the conversations there are. Images aren't kept
there, only that there was one: after a restart it's a gap. Messages come from
anyone, buddy or not, so the conversations are whoever we've talked
to rather than the buddy list.
*/

DM_HISTORY :: 200

DM_State :: enum u8 {
	Received  = 0, // theirs
	Sending   = 1, // ours, not yet taken by the server
	Sent      = 2, // the server has it
	Delivered = 3, // they have it
	Failed    = 4, // it didn't go
}

DM_Message :: struct {
	id:      u64,
	mine:    bool,
	time:    proto.Unix_Time, // theirs: when the server took it; ours: when sent
	text:    string, // owned
	state:   DM_State,
	// An image instead of text (dm_images.odin).
	image:   bool,
	picture: DM_Picture,
}

DM_Conversation :: struct {
	key:      [proto.KEY_SIZE]u8,
	name:     string, // what they last went by, if we know; owned
	messages: [dynamic]DM_Message,
}

// DM_Outgoing is a DM waiting for the server to take it. Sealed once,
// so every resend is the same message.
DM_Outgoing :: struct {
	to:         [proto.KEY_SIZE]u8,
	id:         u64,
	nonce:      [proto.DM_NONCE_SIZE]u8,
	sealed:     [proto.MAX_DM_SEALED]u8,
	sealed_len: int,
	last_send:  time.Tick,
	// An image DM's picture, sealed, and its upload (dm_images.odin).
	image:      []u8, // owned
	upload:     proto.Blob_Sender,
	uploading:  bool,
	tokens:     f32,
	last_chunk: time.Tick,
}

DM_Client :: struct {
	dir:           string, // where the history is kept (store names); owned
	conversations: map[[proto.KEY_SIZE]u8]^DM_Conversation,
	outbox:        [dynamic]DM_Outgoing,
	// The key shared with each user we've messaged, as deriving one
	// takes an X25519.
	keys:          map[[proto.KEY_SIZE]u8][proto.DM_KEY_SIZE]u8,
	// When we last told each of them we're typing.
	last_typing:   map[[proto.KEY_SIZE]u8]time.Tick,
	// The mail sound has played for DMs that waited for us to connect;
	// it plays once per connection however many there were.
	mail_played:   bool,
	// Images being fetched (dm_images.odin).
	fetch:         DM_Fetch,
	next_image_id: u32,
}

// DM_Command sends a DM. `to` is all zero for the user called `name`
// (headless mode's /dm).
DM_Command :: struct {
	to:   [proto.KEY_SIZE]u8,
	name: string, // owned by the command
	text: string, // owned by the command
}

// DM_Typing_Command says we're typing to someone.
DM_Typing_Command :: struct {
	to: [proto.KEY_SIZE]u8,
}

// dm_open loads the DM history kept next to `key_path` and hands it to
// the UI.
dm_open :: proc(c: ^Voice_Client, key_path: string) {
	c.dms.dir = store_sibling(key_path, "dms")
	index_name := dm_store_name(c, "index")
	if !common.store_exists(index_name) {
		return
	}
	index, ok := common.store_read(index_name, context.temp_allocator)
	if !ok {
		return
	}
	for line in strings.split_lines_iterator(&index) {
		key, key_ok := parse_user_key(strings.trim_space(line))
		if key_ok && key not_in c.dms.conversations {
			conv := dm_load_conversation(c, key)
			c.dms.conversations[key] = conv
			publish_dm_conversation(c, conv, unread = false)
		}
	}
}

dm_destroy :: proc(c: ^Voice_Client) {
	for _, conv in c.dms.conversations {
		conversation_destroy(conv)
	}
	delete(c.dms.conversations)
	for &out in c.dms.outbox {
		outgoing_destroy(&out)
	}
	delete(c.dms.outbox)
	dm_fetch_destroy(c)
	for _, &k in c.dms.keys {
		crypto.zero_explicit(&k, size_of(k))
	}
	delete(c.dms.keys)
	delete(c.dms.last_typing)
	delete(c.dms.dir)
}

outgoing_destroy :: proc(out: ^DM_Outgoing) {
	delete(out.image)
	proto.blob_sender_destroy(&out.upload)
	out.image = nil
}

@(private = "file")
conversation_destroy :: proc(conv: ^DM_Conversation) {
	for m in conv.messages {
		message_destroy(m)
	}
	delete(conv.messages)
	delete(conv.name)
	free(conv)
}

// dm_send seals a DM to `to` and queues it. A zero `to` means the user
// called `name`, who has to be online for that.
dm_send :: proc(c: ^Voice_Client, to_or_zero: [proto.KEY_SIZE]u8, name, raw: string) {
	to, found := dm_recipient(c, to_or_zero, name)
	if !found {
		return
	}
	buf: [proto.MAX_DM_SIZE]u8
	text := proto.sanitize_text(raw, buf[:])
	if text == "" {
		return
	}
	key, ok := dm_shared_key(c, to)
	if !ok {
		log.warnf("dm: %s isn't a usable key", fingerprint(to))
		return
	}
	out := DM_Outgoing {
		to = to,
		id = random_id(),
	}
	body_buf: [proto.MAX_DM_BODY]u8
	nonce, sealed := proto.dm_seal(
		&key,
		c.my_key,
		to,
		out.id,
		.Body,
		proto.encode_dm_text(&body_buf, text),
		out.sealed[:],
	)
	out.nonce, out.sealed_len = nonce, len(sealed)
	append(&c.dms.outbox, out)

	conv := dm_conversation(c, to)
	add_message(
		conv,
		{
			id = out.id,
			mine = true,
			time = unix_now(),
			text = strings.clone(text),
			state = .Sending,
		},
	)
	dm_save(c, conv)
	publish_dm_conversation(c, conv, unread = false)
	// Whatever comes next is a new bout of typing.
	delete_key(&c.dms.last_typing, to)
	if len(c.dms.outbox) == 1 {
		drive_dm(c)
	}
}

// dm_recipient is who a DM goes to: `to`, or if that's all zero, the
// user here called `name`. Not ourselves.
dm_recipient :: proc(
	c: ^Voice_Client,
	to: [proto.KEY_SIZE]u8,
	name: string,
) -> (
	key: [proto.KEY_SIZE]u8,
	ok: bool,
) {
	key = to
	if key == {} {
		if c.channels.have_state {
			for u in c.channels.state.users {
				if u.name == name && u.num != my_num(c) {
					key, ok = u.key, true
					break
				}
			}
		}
		if !ok {
			log.warnf("dm: there's nobody called %q here", name)
			return
		}
	}
	return key, key != c.my_key
}

// dm_typing tells `to` we're typing, if we haven't lately.
dm_typing :: proc(c: ^Voice_Client, to: [proto.KEY_SIZE]u8) {
	if !c.has_current {
		return
	}
	if last, ok := c.dms.last_typing[to]; ok && time.tick_since(last) < TYPING_SEND_INTERVAL {
		return
	}
	c.dms.last_typing[to] = time.tick_now()
	buf: [proto.DM_TYPING_SIZE]u8
	send_data(c, proto.encode_dm_typing(&buf, to))
}

// drive_dm keeps the oldest DM the server hasn't taken going. One at a
// time, so they arrive in the order they were written.
drive_dm :: proc(c: ^Voice_Client) {
	if len(c.dms.outbox) == 0 || !c.has_current {
		return
	}
	out := &c.dms.outbox[0]
	if out.image != nil {
		dm_image_upload_step(c, out)
		return
	}
	if out.last_send != {} && time.tick_since(out.last_send) < proto.CONTROL_RESEND {
		return
	}
	out.last_send = time.tick_now()
	buf: [proto.MAX_DM_SIZE_ON_WIRE]u8
	send_data(
		c,
		proto.encode_dm_send(buf[:], out.id, out.to, out.nonce, out.sealed[:out.sealed_len]),
	)
}

handle_dm_sent :: proc(c: ^Voice_Client, pt: []u8) {
	id, result := proto.decode_dm_sent(pt)
	if len(c.dms.outbox) == 0 || c.dms.outbox[0].id != id {
		return // a late duplicate
	}
	to := c.dms.outbox[0].to
	outgoing_destroy(&c.dms.outbox[0])
	ordered_remove(&c.dms.outbox, 0)
	state := DM_State.Sent
	switch result {
	case .Held:
	case .Offline:
		state = .Failed
		log.warnf("dm: %s isn't online, so the image wasn't sent", fingerprint(to))
	case .Full:
		fallthrough
	case:
		state = .Failed
		log.warnf("dm: the server refused a DM to %s (%v)", fingerprint(to), result)
	}
	set_state(c, to, id, state)
	drive_dm(c)
}

handle_dm_delivered :: proc(c: ^Voice_Client, pt: []u8) {
	id, to := proto.decode_dm_key_message(pt)
	set_state(c, to, id, .Delivered)
}

// handle_dm takes a DM in, and acknowledges it: whether or not it's
// new, and even if it won't open, as the server would only send it again.
handle_dm :: proc(c: ^Voice_Client, pt: []u8) {
	id, from, sent_at, flags, nonce, sealed := proto.decode_dm(pt)
	defer {
		ack: [proto.DM_ACK_SIZE]u8
		send_data(c, proto.encode_dm_key_message(&ack, .DM_Ack, id, from))
	}
	if conv := c.dms.conversations[from] or_else nil; conv != nil {
		for m in conv.messages {
			if !m.mine && m.id == id {
				return // we have it already
			}
		}
	}
	key, key_ok := dm_shared_key(c, from)
	out: [proto.MAX_DM_BODY]u8
	body, ok := proto.dm_open(&key, from, c.my_key, id, .Body, nonce, sealed, out[:])
	content, raw, picture, body_ok := proto.decode_dm_body(body)
	if !key_ok || !ok || !body_ok {
		log.warnf("dm: dropping one from %s that doesn't open", fingerprint(from))
		return
	}
	buf: [proto.MAX_DM_SIZE]u8
	text := proto.sanitize_text(raw, buf[:])
	msg := DM_Message {
		id    = id,
		time  = sent_at,
		text  = strings.clone(text),
		state = .Received,
	}
	if content == .Image {
		msg.image = true
		msg.picture = dm_picture(c, picture, .Wanted)
		text = fmt.tprintf("[image, %dx%d]", picture.width, picture.height)
	}

	conv := dm_conversation(c, from)
	if c.channels.have_state {
		for u in c.channels.state.users {
			if u.key == from && u.name != "" && u.name != conv.name {
				delete(conv.name)
				conv.name = strings.clone(u.name)
			}
		}
	}
	add_message(conv, msg)
	if msg.image {
		dm_fetch_want(c, from, id)
	}
	dm_save(c, conv)
	publish_dm_conversation(c, conv, unread = true)
	// DMs that waited for us are mail, announced once as we join; one
	// sent while we're here is a message like the chat's.
	if .Waited not_in flags {
		voice_notification_play(&c.voice, .Message)
	} else if !c.dms.mail_played {
		c.dms.mail_played = true
		voice_notification_play(&c.voice, .Mail)
	}
	if c.view == nil {
		// Headless: the log is the only place to show it.
		log.infof(
			"[dm] %s%s: %s",
			conv.name if conv.name != "" else fingerprint(from),
			" (while you were away)" if .Waited in flags else "",
			text,
		)
	}
}

handle_dm_typing :: proc(c: ^Voice_Client, pt: []u8) {
	from := proto.decode_dm_typing(pt)
	publish_dm_typing(c, from)
	if c.view == nil {
		log.infof("[dm] %s is typing", fingerprint(from))
	}
}

// dm_conversation returns the conversation with `key`, starting one
// (and listing it in the index) if there's none yet.
dm_conversation :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]u8) -> ^DM_Conversation {
	if conv := c.dms.conversations[key] or_else nil; conv != nil {
		return conv
	}
	conv := new(DM_Conversation)
	conv.key = key
	c.dms.conversations[key] = conv
	dm_save_index(c)
	return conv
}

// add_message appends to a conversation, dropping the oldest past
// DM_HISTORY.
add_message :: proc(conv: ^DM_Conversation, m: DM_Message) {
	append(&conv.messages, m)
	for len(conv.messages) > DM_HISTORY {
		message_destroy(conv.messages[0])
		ordered_remove(&conv.messages, 0)
	}
}

@(private = "file")
message_destroy :: proc(m: DM_Message) {
	delete(m.text)
	delete(m.picture.jpeg)
}

// set_state updates one of our messages to `to`, and shows and saves it.
set_state :: proc(c: ^Voice_Client, to: [proto.KEY_SIZE]u8, id: u64, state: DM_State) {
	conv := c.dms.conversations[to] or_else nil
	if conv == nil {
		return
	}
	for &m in conv.messages {
		// Never back: a late DM_Sent mustn't undo a Delivered.
		if m.mine && m.id == id && state > m.state {
			m.state = state
			dm_save(c, conv)
			publish_dm_conversation(c, conv, unread = false)
			return
		}
	}
}

dm_shared_key :: proc(
	c: ^Voice_Client,
	them: [proto.KEY_SIZE]u8,
) -> (
	key: [proto.DM_KEY_SIZE]u8,
	ok: bool,
) {
	if k, have := c.dms.keys[them]; have {
		return k, true
	}
	key = proto.dm_key(&c.key, them) or_return
	c.dms.keys[them] = key
	return key, true
}

random_id :: proc() -> (id: u64) {
	for id == 0 {
		crypto.rand_bytes(([^]byte)(&id)[:size_of(id)])
	}
	return
}

unix_now :: proc() -> proto.Unix_Time {
	return proto.Unix_Time(time.time_to_unix(time.now()))
}

// Storage. A conversation is saved whole whenever it changes; it's at
// most DM_HISTORY short messages, trimmed further if it wouldn't fit in
// the store (common.STORE_MAX_SIZE).

@(private = "file")
Saved_Conversation :: struct {
	name:     string,
	messages: []Saved_Message,
}

// The id as a hex string, as JSON numbers don't reliably carry 64 bits.
@(private = "file")
Saved_Message :: struct {
	id:     string,
	mine:   bool,
	time:   u64,
	text:   string,
	state:  DM_State,
	// An image, which isn't kept: only its size, for the gap it leaves.
	image:  bool,
	width:  u16,
	height: u16,
}

@(private = "file")
dm_store_name :: proc(c: ^Voice_Client, name: string) -> string {
	return strings.concatenate({c.dms.dir, "/", name}, context.temp_allocator)
}

@(private = "file")
conversation_store_name :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]u8) -> string {
	return dm_store_name(c, strings.concatenate({user_key(key), ".json"}, context.temp_allocator))
}

@(private = "file")
dm_save_index :: proc(c: ^Voice_Client) {
	if c.dms.dir == "" {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for key in c.dms.conversations {
		strings.write_string(&b, user_key(key))
		strings.write_byte(&b, '\n')
	}
	common.store_write(dm_store_name(c, "index"), strings.to_string(b), private = true)
}

dm_save :: proc(c: ^Voice_Client, conv: ^DM_Conversation) {
	if c.dms.dir == "" {
		return
	}
	messages := make([]Saved_Message, len(conv.messages), context.temp_allocator)
	for m, i in conv.messages {
		messages[i] = {
			id     = hex_u64(m.id),
			mine   = m.mine,
			time   = u64(m.time),
			text   = m.text,
			state  = m.state,
			image  = m.image,
			width  = m.picture.width,
			height = m.picture.height,
		}
	}
	// The oldest go first if it's too much for the store.
	saved := Saved_Conversation {
		name     = conv.name,
		messages = messages,
	}
	for {
		data, err := json.marshal(saved, allocator = context.temp_allocator)
		if err != nil {
			log.errorf("dm: could not encode a conversation: %v", err)
			return
		}
		if len(data) <= common.STORE_MAX_SIZE || len(saved.messages) == 0 {
			common.store_write(conversation_store_name(c, conv.key), string(data), private = true)
			return
		}
		saved.messages = saved.messages[max(len(saved.messages) / 8, 1):]
	}
}

@(private = "file")
dm_load_conversation :: proc(c: ^Voice_Client, key: [proto.KEY_SIZE]u8) -> ^DM_Conversation {
	conv := new(DM_Conversation)
	conv.key = key
	data, ok := common.store_read(conversation_store_name(c, key), context.temp_allocator)
	if !ok {
		return conv
	}
	saved: Saved_Conversation
	if err := json.unmarshal(transmute([]u8)data, &saved, allocator = context.temp_allocator);
	   err != nil {
		log.warnf("dm: ignoring an unreadable conversation with %s: %v", fingerprint(key), err)
		return conv
	}
	conv.name = strings.clone(saved.name)
	for s in saved.messages {
		id, id_ok := strconv.parse_u64_of_base(s.id, 16)
		if !id_ok {
			continue
		}
		state := s.state
		// Still unconfirmed when we stopped: it may or may not have
		// gone, and it won't be sent again.
		if state == .Sending {
			state = .Failed
		}
		m := DM_Message {
			id    = id,
			mine  = s.mine,
			time  = proto.Unix_Time(s.time),
			text  = strings.clone(s.text),
			state = state,
			image = s.image,
		}
		if s.image {
			m.picture = dm_picture(c, {width = s.width, height = s.height}, .Gone)
		}
		add_message(conv, m)
	}
	return conv
}

@(private = "file")
hex_u64 :: proc(v: u64) -> string {
	return fmt.tprintf("%x", v)
}
