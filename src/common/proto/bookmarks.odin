package proto

import "core:encoding/endian"

// Bookmarks: messages that an account marked to come back to, in a list of
// its own that nobody else sees (Mattermost's saved messages).
//
// 	Bookmark_Set      [id u64][on u8]
// 	Bookmarks_Get     [before_time u64][before u64]
// 	                  ->  [count u16][more u8] per bookmark: [time u64] message,
// 	                  the newest bookmark first
//
// 	Bookmarks         [count u16][id u64]...: every message the account has
// 	                  bookmarked, in the login sync (rpc.odin)
// 	Bookmark_Changed  [id u64][time u64][on u8]: the account bookmarked a
// 	                  message (`on`) or removed its bookmark
//
// Any message that the account may read can be bookmarked, except a deleted
// one; an account has at most MAX_BOOKMARKS (beyond that the answer is
// Too_Large). A bookmark is a reference to the message, not a copy: the list
// shows it as it is now, and a message that is deleted later stays in it as
// deleted. Removing a bookmark always succeeds, also for a message the account
// can no longer read.
//
// Bookmarks_Get answers with a page of the list, at most BOOKMARKS_PAGE or
// fewer if they wouldn't fit in one stream message, starting after the
// bookmark at (`before_time`, `before`), or from the newest with both 0.
// `time` is when the message was bookmarked. To continue, ask again with the
// last one's time and message id. Messages in conversations that the account
// can't read (any more) are left out, but their bookmarks are kept, so they
// come back when it may read there again. A message that is purged
// (purge.odin) takes its bookmarks with it.
//
// Bookmark_Changed is sent to every connection of the account, including the
// one that asked, so that all of them agree on which messages are bookmarked.

MAX_BOOKMARKS :: 1000
BOOKMARKS_PAGE :: 50

BOOKMARK_SET_SIZE :: 8 + 1
BOOKMARKS_GET_SIZE :: 8 + 8
BOOKMARK_CHANGED_SIZE :: 8 + 8 + 1
BOOKMARKS_MAX_SIZE :: 2 + MAX_BOOKMARKS * 8

// Bookmark is one entry of a Bookmarks_Get page: a message, and when it was
// bookmarked.
Bookmark :: struct {
	time: Unix_Ms,
	msg:  Message,
}

encode_bookmark_set :: proc(out: ^[BOOKMARK_SET_SIZE]u8, id: Msg_Id, on: bool) -> []u8 {
	endian.unchecked_put_u64le(out[0:], u64(id))
	out[8] = u8(on)
	return out[:]
}

decode_bookmark_set :: proc(body: []u8) -> (id: Msg_Id, on: bool, ok: bool) {
	if len(body) != BOOKMARK_SET_SIZE || body[8] > 1 {
		return
	}
	id = Msg_Id(endian.unchecked_get_u64le(body))
	return id, body[8] != 0, id != 0
}

encode_bookmarks_get :: proc(
	out: ^[BOOKMARKS_GET_SIZE]u8,
	before_time: Unix_Ms,
	before: Msg_Id,
) -> []u8 {
	endian.unchecked_put_u64le(out[0:], u64(before_time))
	endian.unchecked_put_u64le(out[8:], u64(before))
	return out[:]
}

decode_bookmarks_get :: proc(body: []u8) -> (before_time: Unix_Ms, before: Msg_Id, ok: bool) {
	if len(body) != BOOKMARKS_GET_SIZE {
		return
	}
	before_time = Unix_Ms(endian.unchecked_get_u64le(body[0:]))
	before = Msg_Id(endian.unchecked_get_u64le(body[8:]))
	return before_time, before, true
}

// encode_bookmarks_page writes a Bookmarks_Get response with as many of
// `list` as fit in `out`. It says that there are more if not all of them fit,
// or if `more`. `count` is how many it holds.
encode_bookmarks_page :: proc(
	out: []u8,
	list: []Bookmark,
	more: bool,
) -> (
	body: []u8,
	count: int,
) {
	w := Writer {
		buf = out,
	}
	put_u16(&w, 0)
	put_u8(&w, 0)
	for b in list {
		if w.pos + 8 + message_size(b.msg) > len(out) || count == int(max(u16)) {
			break
		}
		put_u64(&w, u64(b.time))
		put_message(&w, b.msg)
		count += 1
	}
	if w.overflow {
		return nil, 0
	}
	endian.unchecked_put_u16le(out[0:], u16(count))
	out[2] = u8(more || count < len(list))
	return out[:w.pos], count
}

// decode_bookmarks_page reads a Bookmarks_Get response into `buf`. The strings
// point into `body`.
decode_bookmarks_page :: proc(
	body: []u8,
	buf: []Bookmark,
) -> (
	list: []Bookmark,
	more: bool,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	more = get_u8(&r) != 0
	if r.overflow || count > len(buf) {
		return
	}
	for i in 0 ..< count {
		buf[i].time = Unix_Ms(get_u64(&r))
		buf[i].msg = get_message(&r) or_return
	}
	if r.overflow || r.pos != len(body) {
		return
	}
	return buf[:count], more, true
}

// encode_bookmarks writes the Bookmarks event, with at most MAX_BOOKMARKS ids.
encode_bookmarks :: proc(out: ^[BOOKMARKS_MAX_SIZE]u8, ids: []Msg_Id) -> []u8 {
	n := min(len(ids), MAX_BOOKMARKS)
	endian.unchecked_put_u16le(out[0:], u16(n))
	for id, i in ids[:n] {
		endian.unchecked_put_u64le(out[2 + i * 8:], u64(id))
	}
	return out[:2 + n * 8]
}

// decode_bookmarks reads the Bookmarks event into `buf`.
decode_bookmarks :: proc(body: []u8, buf: ^[MAX_BOOKMARKS]Msg_Id) -> (ids: []Msg_Id, ok: bool) {
	if len(body) < 2 {
		return
	}
	n := int(endian.unchecked_get_u16le(body))
	if n > MAX_BOOKMARKS || len(body) != 2 + n * 8 {
		return
	}
	for i in 0 ..< n {
		buf[i] = Msg_Id(endian.unchecked_get_u64le(body[2 + i * 8:]))
	}
	return buf[:n], true
}

encode_bookmark_changed :: proc(
	out: ^[BOOKMARK_CHANGED_SIZE]u8,
	id: Msg_Id,
	time: Unix_Ms,
	on: bool,
) -> []u8 {
	endian.unchecked_put_u64le(out[0:], u64(id))
	endian.unchecked_put_u64le(out[8:], u64(time))
	out[16] = u8(on)
	return out[:]
}

decode_bookmark_changed :: proc(body: []u8) -> (id: Msg_Id, time: Unix_Ms, on: bool, ok: bool) {
	if len(body) != BOOKMARK_CHANGED_SIZE || body[16] > 1 {
		return
	}
	id = Msg_Id(endian.unchecked_get_u64le(body[0:]))
	time = Unix_Ms(endian.unchecked_get_u64le(body[8:]))
	return id, time, body[16] != 0, id != 0
}
