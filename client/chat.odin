package client

import "core:crypto"
import "core:log"
import "core:strings"
import "core:time"

import "../proto"

// Typing notices go out at most this often while typing, and are shown
// for TYPING_SHOW after the last one arrives.
TYPING_SEND_INTERVAL :: 3 * time.Second
TYPING_SHOW :: 5 * time.Second
// Messages arriving this soon after a stream starts are taken to be the
// channel's history rather than news, and don't count as unread.
CHAT_HISTORY_WINDOW :: 1500 * time.Millisecond

Chat_Outgoing :: struct {
	nonce: u64,
	text:  string, // owned
}

// Chat_Client is our end of the text chat (see proto/chat.odin): the
// stream of the current channel's messages, and messages waiting for
// the server to confirm them.
Chat_Client :: struct {
	started:     bool,
	channel:     u16,
	base:        u32,
	last:        u32, // newest message id taken
	started_at:  time.Tick,

	// Sent one at a time, so the server posts them in order.
	outbox:      [dynamic]Chat_Outgoing,
	last_send:   time.Tick,
	last_typing: time.Tick,
}

chat_destroy :: proc(c: ^Voice_Client) {
	for m in c.chat.outbox {
		delete(m.text)
	}
	delete(c.chat.outbox)
}

// chat_channel_changed starts over when we end up in another channel;
// the server sends that channel's history.
chat_channel_changed :: proc(c: ^Voice_Client) {
	c.chat.started = false
	publish_chat_reset(c)
}

// chat_send queues a message for the channel we're in.
chat_send :: proc(c: ^Voice_Client, raw: string) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_text(raw, buf[:])
	if text == "" {
		return
	}
	nonce: u64
	crypto.rand_bytes(([^]byte)(&nonce)[:size_of(nonce)])
	append(&c.chat.outbox, Chat_Outgoing{nonce, strings.clone(text)})
	// Whatever comes next is a new bout of typing.
	c.chat.last_typing = {}
	publish_outbox(c)
	if len(c.chat.outbox) == 1 {
		c.chat.last_send = {}
		drive_chat(c)
	}
}

// chat_typing tells the channel we're typing, if we haven't lately.
chat_typing :: proc(c: ^Voice_Client) {
	if !c.has_current ||
	   (c.chat.last_typing != {} && time.tick_since(c.chat.last_typing) < TYPING_SEND_INTERVAL) {
		return
	}
	c.chat.last_typing = time.tick_now()
	msg := [proto.TYPING_UP_SIZE]u8{u8(proto.Message_Kind.Typing)}
	send_data(c, msg[:])
}

// drive_chat (re)sends the oldest unconfirmed message.
drive_chat :: proc(c: ^Voice_Client) {
	ch := &c.chat
	if len(ch.outbox) == 0 ||
	   !c.has_current ||
	   (ch.last_send != {} && time.tick_since(ch.last_send) < proto.CONTROL_RESEND) {
		return
	}
	buf: [proto.CHAT_SEND_HEADER_SIZE + proto.MAX_CHAT_SIZE]u8
	send_data(c, proto.encode_chat_send(buf[:], ch.outbox[0].nonce, ch.outbox[0].text))
	ch.last_send = time.tick_now()
}

handle_chat_sent :: proc(c: ^Voice_Client, pt: []byte) {
	ch := &c.chat
	if len(ch.outbox) == 0 || ch.outbox[0].nonce != proto.decode_chat_sent(pt) {
		return // a late duplicate
	}
	delete(ch.outbox[0].text)
	ordered_remove(&ch.outbox, 0)
	publish_outbox(c)
	ch.last_send = {}
	drive_chat(c)
}

handle_chat :: proc(c: ^Voice_Client, pt: []byte) {
	entries_buf: [128]proto.Chat_Entry
	channel, base, entries, ok := proto.decode_chat(pt, entries_buf[:])
	// Messages for a channel we aren't (yet) in are dropped; the server
	// resends them if we get there.
	if !ok || !c.channels.have_state || channel != c.channels.state.your_channel {
		return
	}
	ch := &c.chat
	if !ch.started || ch.channel != channel || ch.base != base {
		if ch.started {
			// Same channel, new base: we fell behind and missed some.
			publish_chat_reset(c)
		}
		ch.started = true
		ch.channel = channel
		ch.base = base
		ch.last = base
		ch.started_at = time.tick_now()
	}
	for e in entries {
		if e.id != ch.last + 1 {
			continue
		}
		ch.last = e.id
		unread := e.sender != my_num(c) && time.tick_since(ch.started_at) > CHAT_HISTORY_WINDOW
		publish_chat(c, e, unread)
		if c.view == nil {
			// Headless: the log is the only place to show it.
			log.infof("[chat] %s: %s", chat_sender_name(c, e), e.text)
		}
	}
	ack: [proto.CHAT_RECEIVED_SIZE]u8
	send_data(c, proto.encode_chat_received(&ack, channel, ch.last))
}

handle_typing :: proc(c: ^Voice_Client, pt: []byte) {
	if len(pt) != proto.TYPING_DOWN_SIZE || !in_settled_channel(c) {
		return
	}
	user := proto.decode_typing_down(pt)
	publish_typing(c, user)
	if c.view == nil {
		log.infof("[chat] %s is typing", display_name(c.channels.state.users, user))
	}
}

// chat_sender_name is who sent a message: their current display name if
// they're still around, else the name they had then.
chat_sender_name :: proc(c: ^Voice_Client, e: proto.Chat_Entry) -> string {
	if c.channels.have_state && proto.find_user(&c.channels.state, e.sender) != nil {
		return display_name(c.channels.state.users, e.sender)
	}
	return e.name if e.name != "" else "(unnamed)"
}
