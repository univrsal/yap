package proto

/*
Purging: removing old messages, or only their pictures, for good
(phase 15). The server does it on its own for what its config says to
keep no longer, and on demand for whoever has Permission.Purge.

	Purge        [conv u32][before u64][what u8]
	         ->  [messages u32][blobs u32]

	Msgs_Purged  [conv u32][before u64][what u8]

A Purge names a conversation, or 0 for all of them, and a time in Unix
milliseconds: what was posted before it goes. `what` says whether the
messages go, or only the pictures in them. It's answered once it's done,
which can take a while, with how many messages went (or lost their
picture) and how many stored files were removed with them. One purge
asked for at a time: another while one is under way is Conflict.

Pinned messages are kept, pictures and all, and so is a thread's root
while replies to it are kept. Everything else goes with its reactions,
mentions and pins; unlike a deleted message nothing is left in its place.

Msgs_Purged tells the members of a conversation that its messages with
ids below `before` are gone, but for those kept (which they can ask for
again), or with Purge_What.Images, that those messages' pictures are,
but for pinned ones. A message whose picture is gone is still an Image,
with blob 0.
*/

Purge_What :: enum u8 {
	Messages = 0,
	Images   = 1,
}

PURGE_SIZE :: 4 + 8 + 1
PURGE_ANSWER_SIZE :: 4 + 4
MSGS_PURGED_SIZE :: 4 + 8 + 1

Purge :: struct {
	conv:   Conv_Id, // 0 for all
	before: Unix_Ms,
	what:   Purge_What,
}

encode_purge :: proc(out: ^[PURGE_SIZE]u8, p: Purge) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(p.conv))
	put_u64(&w, u64(p.before))
	put_u8(&w, u8(p.what))
	return out[:]
}

decode_purge :: proc(body: []u8) -> (p: Purge, ok: bool) {
	r := Reader {
		buf = body,
	}
	p.conv = Conv_Id(get_u32(&r))
	p.before = Unix_Ms(get_u64(&r))
	what := get_u8(&r)
	if r.overflow || what > u8(max(Purge_What)) || p.before == 0 {
		return
	}
	p.what = Purge_What(what)
	return p, true
}

encode_purge_answer :: proc(out: ^[PURGE_ANSWER_SIZE]u8, messages, blobs: int) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(min(u64(max(messages, 0)), u64(max(u32)))))
	put_u32(&w, u32(min(u64(max(blobs, 0)), u64(max(u32)))))
	return out[:]
}

decode_purge_answer :: proc(body: []u8) -> (messages, blobs: int, ok: bool) {
	r := Reader {
		buf = body,
	}
	messages = int(get_u32(&r))
	blobs = int(get_u32(&r))
	return messages, blobs, !r.overflow
}

Msgs_Purged :: struct {
	conv:   Conv_Id,
	before: Msg_Id,
	what:   Purge_What,
}

encode_msgs_purged :: proc(out: ^[MSGS_PURGED_SIZE]u8, p: Msgs_Purged) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(p.conv))
	put_u64(&w, u64(p.before))
	put_u8(&w, u8(p.what))
	return out[:]
}

decode_msgs_purged :: proc(body: []u8) -> (p: Msgs_Purged, ok: bool) {
	r := Reader {
		buf = body,
	}
	p.conv = Conv_Id(get_u32(&r))
	p.before = Msg_Id(get_u64(&r))
	what := get_u8(&r)
	if r.overflow || what > u8(max(Purge_What)) {
		return
	}
	p.what = Purge_What(what)
	return p, true
}
