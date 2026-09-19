package proto

import "core:encoding/endian"

/*
Text chat, per channel. All of it rides in Data packets like the other
messages (see messages.odin for the kinds).

	client -> server  Chat_Send      [kind][nonce u64][text_len u16][text]
	server -> client  Chat_Sent      [kind][nonce u64]
	server -> client  Chat           [kind][channel u16][base u32][count u8] entries...
	                   entry:        [id u32][sender u32][time u32][name_len u8][name][text_len u16][text]
	client -> server  Chat_Received  [kind][channel u16][id u32]
	client -> server  Typing         [kind]
	server -> client  Typing         [kind][user u32]

Sending: each message has a random nonce and is resent until Chat_Sent
echoes it. The server remembers recent nonces per user, so resends are
never posted twice (whatever happens to sessions in between).

Receiving: the server numbers each channel's messages 1, 2, 3, ... and
keeps the last few. Per user it sends a stream starting after `base`
(on joining a channel: just before the oldest message it keeps, so the
history comes first) and resends everything after the id the client has
acknowledged with Chat_Received, which is cumulative: the client only
takes messages in order, id = last + 1. A different channel or base in a
Chat packet means a new stream (the user moved, or fell so far behind
that messages were dropped): the client starts over from `base`.

Typing notices are unreliable and only mean "typing recently".
*/

MAX_CHAT_SIZE :: 500 // bytes of UTF-8

// Chat_Entry is one message. Strings point into the packet it came from.
Chat_Entry :: struct {
	id:     u32,
	sender: u32, // user number (may have left since)
	time:   u32, // unix seconds, server clock
	name:   string, // the sender's name when it was sent
	text:   string,
}

CHAT_SENT_SIZE :: 1 + 8
CHAT_RECEIVED_SIZE :: 1 + 2 + 4
CHAT_HEADER_SIZE :: 1 + 2 + 4 + 1
CHAT_SEND_HEADER_SIZE :: 1 + 8 + 2
TYPING_UP_SIZE :: 1
TYPING_DOWN_SIZE :: 1 + 4

// encode_chat_send expects already sanitized text.
encode_chat_send :: proc(out: []u8, nonce: u64, text: string) -> []u8 {
	n := min(len(text), MAX_CHAT_SIZE)
	out[0] = u8(Message_Kind.Chat_Send)
	endian.unchecked_put_u64le(out[1:], nonce)
	endian.unchecked_put_u16le(out[9:], u16(n))
	copy(out[CHAT_SEND_HEADER_SIZE:], text[:n])
	return out[:CHAT_SEND_HEADER_SIZE + n]
}

// decode_chat_send returns the raw text; sanitize it before use.
decode_chat_send :: proc(pt: []u8) -> (nonce: u64, text: string) {
	nonce = endian.unchecked_get_u64le(pt[1:])
	n := int(endian.unchecked_get_u16le(pt[9:]))
	return nonce, string(pt[CHAT_SEND_HEADER_SIZE:][:n])
}

encode_chat_sent :: proc(out: ^[CHAT_SENT_SIZE]u8, nonce: u64) -> []u8 {
	out[0] = u8(Message_Kind.Chat_Sent)
	endian.unchecked_put_u64le(out[1:], nonce)
	return out[:]
}

decode_chat_sent :: proc(pt: []u8) -> u64 {
	return endian.unchecked_get_u64le(pt[1:])
}

encode_chat_received :: proc(out: ^[CHAT_RECEIVED_SIZE]u8, channel: u16, id: u32) -> []u8 {
	out[0] = u8(Message_Kind.Chat_Received)
	endian.unchecked_put_u16le(out[1:], channel)
	endian.unchecked_put_u32le(out[3:], id)
	return out[:]
}

decode_chat_received :: proc(pt: []u8) -> (channel: u16, id: u32) {
	return endian.unchecked_get_u16le(pt[1:]), endian.unchecked_get_u32le(pt[3:])
}

encode_typing_down :: proc(out: ^[TYPING_DOWN_SIZE]u8, user: u32) -> []u8 {
	out[0] = u8(Message_Kind.Typing)
	endian.unchecked_put_u32le(out[1:], user)
	return out[:]
}

decode_typing_down :: proc(pt: []u8) -> (user: u32) {
	return endian.unchecked_get_u32le(pt[1:])
}

// encode_chat writes a Chat packet with as many of `entries` (in order,
// consecutive ids) as fit in `out`, and returns it and how many it took.
encode_chat :: proc(out: []u8, channel: u16, base: u32, entries: []Chat_Entry) -> (msg: []u8, count: int) {
	if len(out) < CHAT_HEADER_SIZE {
		return
	}
	out[0] = u8(Message_Kind.Chat)
	endian.unchecked_put_u16le(out[1:], channel)
	endian.unchecked_put_u32le(out[3:], base)
	w := Writer {
		buf = out,
		pos = CHAT_HEADER_SIZE,
	}
	for e in entries[:min(len(entries), int(max(u8)))] {
		size := 4 + 4 + 4 + 1 + len(e.name) + 2 + len(e.text)
		if w.pos + size > len(out) || len(e.name) > MAX_NAME_SIZE || len(e.text) > MAX_CHAT_SIZE {
			break
		}
		put_u32(&w, e.id)
		put_u32(&w, e.sender)
		put_u32(&w, e.time)
		put_u8(&w, u8(len(e.name)))
		put_bytes(&w, transmute([]u8)e.name)
		put_u16(&w, u16(len(e.text)))
		put_bytes(&w, transmute([]u8)e.text)
		count += 1
	}
	out[7] = u8(count)
	return out[:w.pos], count
}

// decode_chat parses a Chat packet into `entries_buf`; names and texts
// point into `pt`.
@(require_results)
decode_chat :: proc(
	pt: []u8,
	entries_buf: []Chat_Entry,
) -> (
	channel: u16,
	base: u32,
	entries: []Chat_Entry,
	ok: bool,
) {
	if len(pt) < CHAT_HEADER_SIZE {
		return
	}
	channel = endian.unchecked_get_u16le(pt[1:])
	base = endian.unchecked_get_u32le(pt[3:])
	count := int(pt[7])
	if count > len(entries_buf) {
		return
	}
	r := Reader {
		buf = pt,
		pos = CHAT_HEADER_SIZE,
	}
	for &e in entries_buf[:count] {
		e.id = get_u32(&r)
		e.sender = get_u32(&r)
		e.time = get_u32(&r)
		name_len := int(get_u8(&r))
		e.name = string(get_bytes(&r, name_len))
		text_len := int(get_u16(&r))
		e.text = string(get_bytes(&r, text_len))
		if r.overflow || name_len > MAX_NAME_SIZE || text_len > MAX_CHAT_SIZE {
			return
		}
	}
	if r.pos != len(pt) {
		return
	}
	return channel, base, entries_buf[:count], true
}
