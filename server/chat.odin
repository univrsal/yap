package server

import "core:log"
import "core:net"
import "core:time"

import "../proto"

// How many messages each channel keeps, and what a user gets on joining.
CHAT_HISTORY :: 50
// Recent Chat_Send nonces remembered per user, so resends aren't posted twice.
CHAT_NONCES :: 32
// Typing notices from one user are relayed at most this often.
TYPING_RELAY_INTERVAL :: 500 * time.Millisecond
// Pokes from one user are passed on at most this often.
POKE_INTERVAL :: time.Second
// Chat packets sent to one user per loop iteration.
CHAT_PACKETS_PER_SYNC :: 8

Chat_Message :: struct {
	id:       u32,
	sender:   u32,
	time:     u32,
	kind:     proto.Chat_Kind,
	image:    proto.Image_Info, // .Image
	name_len: u8,
	text_len: u16, // .Text
	name_buf: [proto.MAX_NAME_SIZE]u8,
	text_buf: [proto.MAX_CHAT_SIZE]u8,
}

// Chat_Log is a channel's recent messages, a ring of CHAT_HISTORY.
Chat_Log :: struct {
	messages: [CHAT_HISTORY]Chat_Message,
	last:     u32, // id of the newest message; ids start at 1
	count:    u32,
}

// Chat_Stream is what one user has been sent of their channel's log.
Chat_Stream :: struct {
	channel:     u16,
	base:        u32, // the stream starts after this id
	acked:       u32, // everything up to here arrived
	sent:        u32, // everything up to here was sent at least once
	last_sent:   time.Tick,
	started:     bool,

	// Chat_Send dedup.
	nonces:      [CHAT_NONCES]u64,
	next_nonce:  int,
	last_typing: time.Tick,
}

chat_oldest :: proc(l: ^Chat_Log) -> u32 {
	return l.last - l.count + 1
}

chat_message :: proc(l: ^Chat_Log, id: u32) -> ^Chat_Message {
	return &l.messages[id % CHAT_HISTORY]
}

chat_entry :: proc(m: ^Chat_Message) -> proto.Chat_Entry {
	return {
		id = m.id,
		sender = m.sender,
		time = m.time,
		name = string(m.name_buf[:m.name_len]),
		kind = m.kind,
		text = string(m.text_buf[:m.text_len]),
		image = m.image,
	}
}

chat_append :: proc(l: ^Chat_Log, sender: u32, name, text: string) {
	m := chat_new(l, sender, name)
	m.kind = .Text
	m.text_len = u16(copy(m.text_buf[:], text))
}

chat_append_image :: proc(l: ^Chat_Log, sender: u32, name: string, image: proto.Image_Info) {
	m := chat_new(l, sender, name)
	m.kind = .Image
	m.image = image
}

// chat_forget_image marks the message carrying an image the server has
// dropped; an id of 0 tells clients it isn't available any more.
chat_forget_image :: proc(l: ^Chat_Log, image: u32) {
	for &m in l.messages {
		if m.kind == .Image && m.image.id == image {
			m.image.id = 0
		}
	}
}

@(private = "file")
chat_new :: proc(l: ^Chat_Log, sender: u32, name: string) -> ^Chat_Message {
	l.last += 1
	l.count = min(l.count + 1, CHAT_HISTORY)
	m := chat_message(l, l.last)
	m^ = {
		id     = l.last,
		sender = sender,
		time   = u32(time.time_to_unix(time.now())),
	}
	m.name_len = u8(copy(m.name_buf[:], name))
	return m
}

// chat_restart makes a user's stream start over with the channel's history.
chat_restart :: proc(u: ^User) {
	u.chat.started = false
}

// handle_poke passes a poke on to the user it's for, as from the user
// whose session it came on - whatever the packet claims (see poke.odin).
// At most one per POKE_INTERVAL from each user, so they can't be used to
// flood someone's desktop with notifications.
handle_poke :: proc(s: ^Server, from: ^User, pt: []byte) {
	_, target, raw := proto.decode_poke(pt)
	now := time.tick_now()
	if from.last_poke != {} && time.tick_diff(from.last_poke, now) < POKE_INTERVAL {
		log.debugf("%s is poking too often", user_label(from))
		return
	}
	for _, u in s.users {
		if u.num != target || u == from {
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			return // not online
		}
		from.last_poke = now
		text_buf: [proto.MAX_POKE_SIZE]u8
		text := proto.sanitize_text(raw, text_buf[:])
		buf: [proto.POKE_MAX_SIZE]u8
		send_message(s, c, proto.encode_poke(&buf, from.num, target, text))
		log.infof("%s poked %s", user_label(from), user_label(u))
		return
	}
}

handle_chat_send :: proc(s: ^Server, c: ^Client, pt: []byte) {
	u := c.user
	nonce, raw := proto.decode_chat_send(pt)

	// Always confirm, even a duplicate: the first Chat_Sent may be lost.
	sent_buf: [proto.CHAT_SENT_SIZE]u8
	send_message(s, c, proto.encode_chat_sent(&sent_buf, nonce))

	for n in u.chat.nonces {
		if n == nonce {
			return
		}
	}
	u.chat.nonces[u.chat.next_nonce] = nonce
	u.chat.next_nonce = (u.chat.next_nonce + 1) % CHAT_NONCES

	text_buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_text(raw, text_buf[:])
	if text == "" {
		return
	}
	// Message content stays out of the log unless debugging.
	log.debugf("%s in %q: %s", user_label(u), s.channels[u.channel], text)
	chat_append(&s.chats[u.channel], u.num, u.name, text)
}

handle_chat_received :: proc(u: ^User, pt: []byte) {
	channel, id := proto.decode_chat_received(pt)
	st := &u.chat
	if st.started && channel == st.channel && id > st.acked && id <= st.sent {
		st.acked = id
	}
}

// handle_typing tells the rest of the channel someone is typing.
handle_typing :: proc(s: ^Server, from: ^User) {
	now := time.tick_now()
	if from.chat.last_typing != {} &&
	   time.tick_diff(from.chat.last_typing, now) < TYPING_RELAY_INTERVAL {
		return
	}
	from.chat.last_typing = now

	buf: [proto.TYPING_DOWN_SIZE]u8
	msg := proto.encode_typing_down(&buf, from.num)
	for _, u in s.users {
		if u == from || u.channel != from.channel {
			continue
		}
		if c := sending_session(s, u); c != nil {
			send_message(s, c, msg)
		}
	}
}

// chat_sync streams each user's channel log to them: new messages right
// away, unacknowledged ones again every CONTROL_RESEND.
chat_sync :: proc(s: ^Server) {
	now := time.tick_now()
	for _, u in s.users {
		l := &s.chats[u.channel]
		st := &u.chat
		// A new stream on joining a channel, and when the user fell so
		// far behind that messages they haven't got were dropped.
		if !st.started || st.channel != u.channel || st.acked + 1 < chat_oldest(l) {
			st.started = true
			st.channel = u.channel
			st.base = chat_oldest(l) - 1
			st.acked = st.base
			st.sent = st.base
			st.last_sent = {}
		}
		if st.acked == l.last {
			continue
		}

		from: u32
		switch {
		case st.last_sent == {} || time.tick_diff(st.last_sent, now) >= proto.CONTROL_RESEND:
			from = st.acked + 1
		case st.sent < l.last:
			from = st.sent + 1
		case:
			continue
		}
		c := sending_session(s, u)
		if c == nil {
			continue
		}

		entries: [CHAT_HISTORY]proto.Chat_Entry
		n := 0
		for id := from; id <= l.last; id += 1 {
			entries[n] = chat_entry(chat_message(l, id))
			n += 1
		}
		out: [proto.MAX_PAYLOAD_SIZE]u8
		pending := entries[:n]
		for _ in 0 ..< CHAT_PACKETS_PER_SYNC {
			if len(pending) == 0 {
				break
			}
			msg, count := proto.encode_chat(out[:], st.channel, st.base, pending)
			if count == 0 {
				break
			}
			send_message(s, c, msg)
			st.sent = max(st.sent, pending[count - 1].id)
			pending = pending[count:]
		}
		st.last_sent = now
	}
}

send_message :: proc(s: ^Server, c: ^Client, msg: []byte) {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	if pkt, ok := proto.seal(&c.session, msg, pkt_buf[:]); ok {
		net.send_udp(s.sock, pkt, c.endpoint)
	}
}
