package proto

import "core:encoding/endian"

/*
When users were last on the server, for the buddy screen to show about
those who aren't here now.

	client -> server  Last_Seen_Get  [kind][count u8][key 32]...
	server -> client  Last_Seen      [kind][count u8]([key 32][time u64])...

The server answers with the time each user it was asked about last left,
0 for one it has never seen, and now for one who's here. It keeps these
across restarts. Both are unreliable; a client just asks again.

It only tells people who have sent each other DMs, both ways, when the
other was last here; for anyone else the answer is LAST_SEEN_HIDDEN.
Whether someone is here now is no secret (everyone gets the user list),
so that's answered for anyone.
*/

// The answer about someone whose last time here isn't shared with the
// one asking.
LAST_SEEN_HIDDEN :: max(Unix_Time)

LAST_SEEN_ENTRY_SIZE :: KEY_SIZE + 8
MAX_LAST_SEEN :: (MAX_PAYLOAD_SIZE - 2) / LAST_SEEN_ENTRY_SIZE

encode_last_seen_get :: proc(out: []u8, keys: [][KEY_SIZE]u8) -> []u8 {
	n := min(len(keys), MAX_LAST_SEEN, (len(out) - 2) / KEY_SIZE)
	out[0] = u8(Message_Kind.Last_Seen_Get)
	out[1] = u8(n)
	for i in 0 ..< n {
		key := keys[i]
		copy(out[2 + i * KEY_SIZE:], key[:])
	}
	return out[:2 + n * KEY_SIZE]
}

// last_seen_get_key is the i-th key in a Last_Seen_Get; message_kind
// has checked the size.
last_seen_get_key :: proc(pt: []u8, i: int) -> (key: [KEY_SIZE]u8) {
	copy(key[:], pt[2 + i * KEY_SIZE:])
	return
}

last_seen_count :: proc(pt: []u8) -> int {
	return int(pt[1])
}

// encode_last_seen writes the answer, one entry per key and time.
encode_last_seen :: proc(out: []u8, keys: [][KEY_SIZE]u8, times: []Unix_Time) -> []u8 {
	n := min(len(keys), len(times), MAX_LAST_SEEN, (len(out) - 2) / LAST_SEEN_ENTRY_SIZE)
	out[0] = u8(Message_Kind.Last_Seen)
	out[1] = u8(n)
	for i in 0 ..< n {
		key := keys[i]
		at := out[2 + i * LAST_SEEN_ENTRY_SIZE:]
		copy(at, key[:])
		endian.unchecked_put_u64le(at[KEY_SIZE:], u64(times[i]))
	}
	return out[:2 + n * LAST_SEEN_ENTRY_SIZE]
}

// last_seen_entry is the i-th entry of a Last_Seen; message_kind has
// checked the size.
last_seen_entry :: proc(pt: []u8, i: int) -> (key: [KEY_SIZE]u8, seen: Unix_Time) {
	at := pt[2 + i * LAST_SEEN_ENTRY_SIZE:]
	copy(key[:], at)
	return key, Unix_Time(endian.unchecked_get_u64le(at[KEY_SIZE:]))
}
