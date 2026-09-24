package proto

import "core:encoding/endian"

/*
Text chat, per channel. All of it rides in Data packets like the other
messages (see messages.odin for the kinds).

	client -> server  Chat_Send      [kind][nonce u64][text_len u16][text]
	server -> client  Chat_Sent      [kind][nonce u64]
	server -> client  Chat           [kind][channel u16][base u32][count u8] entries...
	                   entry:        [id u32][sender u32][time u64][name_len u8][name][entry kind u8]
	                   ... text:     [text_len u16][text]
	                   ... image:    [image u32][width u16][height u16][size u32]
	client -> server  Chat_Received  [kind][channel u16][id u32]
	client -> server  Typing         [kind]
	server -> client  Typing         [kind][user u32]
	client -> server  Image_Send     [kind][nonce u64][width u16][height u16][size u32]
	client -> server  Image_Get      [kind][image u32]
	server -> client  Image_Gone     [kind][image u32]

A message is either text or an image, never both. An image message is
posted by announcing it with Image_Send and uploading the JPEG (see
blob.odin); the server answers with Chat_Sent, as for text, once it has
all of it. The entry others receive names an image id, which they ask
for with Image_Get and receive the same way. An id of 0 means the server
no longer keeps that image.

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

// Unix_Time is seconds since the epoch, the server's clock. Distinct so
// it can't be mixed up with an id or another plain integer by accident.
Unix_Time :: distinct u64

Chat_Kind :: enum u8 {
	Text  = 0,
	Image = 1,
}

// Image_Info is what a chat entry says about an image; the bytes
// themselves are fetched with Image_Get.
Image_Info :: struct {
	id:            u32, // 0: the server doesn't have it any more
	width, height: u16, // as sent, in pixels
	size:          u32, // bytes of JPEG
}

// Chat_Entry is one message. Strings point into the packet it came from.
Chat_Entry :: struct {
	id:     u32,
	sender: User_Num, // may have left since
	time:   Unix_Time,
	name:   string, // the sender's name when it was sent
	kind:   Chat_Kind,
	text:   string, // .Text
	image:  Image_Info, // .Image
}

CHAT_SENT_SIZE :: 1 + 8
CHAT_RECEIVED_SIZE :: 1 + 2 + 4
CHAT_HEADER_SIZE :: 1 + 2 + 4 + 1
CHAT_SEND_HEADER_SIZE :: 1 + 8 + 2
TYPING_UP_SIZE :: 1
TYPING_DOWN_SIZE :: 1 + 4
IMAGE_SEND_SIZE :: 1 + 8 + 2 + 2 + 4
IMAGE_GET_SIZE :: 1 + 4
IMAGE_GONE_SIZE :: 1 + 4
// An entry without its name or text: ids, time, lengths and kind.
CHAT_ENTRY_HEADER_SIZE :: 4 + 4 + 8 + 1 + 1
CHAT_IMAGE_ENTRY_SIZE :: CHAT_ENTRY_HEADER_SIZE + 4 + 2 + 2 + 4

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

encode_typing_down :: proc(out: ^[TYPING_DOWN_SIZE]u8, user: User_Num) -> []u8 {
	out[0] = u8(Message_Kind.Typing)
	endian.unchecked_put_u32le(out[1:], u32(user))
	return out[:]
}

decode_typing_down :: proc(pt: []u8) -> (user: User_Num) {
	return User_Num(endian.unchecked_get_u32le(pt[1:]))
}

// encode_chat writes a Chat packet with as many of `entries` (in order,
// consecutive ids) as fit in `out`, and returns it and how many it took.
encode_chat :: proc(
	out: []u8,
	channel: u16,
	base: u32,
	entries: []Chat_Entry,
) -> (
	msg: []u8,
	count: int,
) {
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
		size := CHAT_ENTRY_HEADER_SIZE + len(e.name)
		size += 2 + len(e.text) if e.kind == .Text else 4 + 2 + 2 + 4
		if w.pos + size > len(out) || len(e.name) > MAX_NAME_SIZE || len(e.text) > MAX_CHAT_SIZE {
			break
		}
		put_u32(&w, e.id)
		put_u32(&w, u32(e.sender))
		put_u64(&w, u64(e.time))
		put_u8(&w, u8(len(e.name)))
		put_bytes(&w, transmute([]u8)e.name)
		put_u8(&w, u8(e.kind))
		switch e.kind {
		case .Text:
			put_u16(&w, u16(len(e.text)))
			put_bytes(&w, transmute([]u8)e.text)
		case .Image:
			put_u32(&w, e.image.id)
			put_u16(&w, e.image.width)
			put_u16(&w, e.image.height)
			put_u32(&w, e.image.size)
		}
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
		e = {}
		e.id = get_u32(&r)
		e.sender = User_Num(get_u32(&r))
		e.time = Unix_Time(get_u64(&r))
		name_len := int(get_u8(&r))
		e.name = string(get_bytes(&r, name_len))
		e.kind = Chat_Kind(get_u8(&r))
		switch e.kind {
		case .Text:
			text_len := int(get_u16(&r))
			e.text = string(get_bytes(&r, text_len))
			if text_len > MAX_CHAT_SIZE {
				return
			}
		case .Image:
			e.image = {
				id     = get_u32(&r),
				width  = get_u16(&r),
				height = get_u16(&r),
				size   = get_u32(&r),
			}
			if int(e.image.size) > MAX_BLOB_SIZE {
				return
			}
		case:
			return // a kind from a newer server
		}
		if r.overflow || name_len > MAX_NAME_SIZE {
			return
		}
	}
	if r.pos != len(pt) {
		return
	}
	return channel, base, entries_buf[:count], true
}

// encode_image_send announces an image message: the size the upload
// will be, and what it looks like.
encode_image_send :: proc(out: ^[IMAGE_SEND_SIZE]u8, nonce: u64, info: Image_Info) -> []u8 {
	out[0] = u8(Message_Kind.Image_Send)
	endian.unchecked_put_u64le(out[1:], nonce)
	endian.unchecked_put_u16le(out[9:], info.width)
	endian.unchecked_put_u16le(out[11:], info.height)
	endian.unchecked_put_u32le(out[13:], info.size)
	return out[:]
}

decode_image_send :: proc(pt: []u8) -> (nonce: u64, info: Image_Info) {
	return endian.unchecked_get_u64le(
		pt[1:],
	), {width = endian.unchecked_get_u16le(pt[9:]), height = endian.unchecked_get_u16le(pt[11:]), size = endian.unchecked_get_u32le(pt[13:])}
}

encode_image_get :: proc(out: ^[IMAGE_GET_SIZE]u8, image: u32) -> []u8 {
	out[0] = u8(Message_Kind.Image_Get)
	endian.unchecked_put_u32le(out[1:], image)
	return out[:]
}

// encode_image_gone answers an Image_Get for an image the server no
// longer keeps.
encode_image_gone :: proc(out: ^[IMAGE_GONE_SIZE]u8, image: u32) -> []u8 {
	out[0] = u8(Message_Kind.Image_Gone)
	endian.unchecked_put_u32le(out[1:], image)
	return out[:]
}

decode_image_id :: proc(pt: []u8) -> (image: u32) {
	return endian.unchecked_get_u32le(pt[1:])
}
