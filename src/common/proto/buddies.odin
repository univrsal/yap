package proto

/*
Buddies, and when people were last here: what the buddy screen is made
of, next to an account's direct messages (DM conversations, convs.odin).

	Buddy_Set       [account u32][on u8]
	Last_Seen       [count u16][account u32]...
	            ->  [count u16]([account u32][time u64])...

	Buddy_Changed   [account u32][on u8]: one of ours, added or taken off

An account's buddies are its own business: the people it keeps in its
list, whether they're here or not. Adding someone doesn't ask them or
tell them. The server keeps the list, so it's the same on every device:
each of the account's connections is told of every buddy when it logs
in (Buddy_Changed, between Sync_Begin and Sync_End), and of every change
after.

Last_Seen asks when accounts were last here, in Unix milliseconds: now
for one that's here (anyone can see that anyway, in the snapshot), and
otherwise only to people who have exchanged messages with it, both
having posted in the DM between them. For anyone else it's
LAST_SEEN_HIDDEN, and 0 for an account there isn't.
*/

// The answer about someone whose last time here isn't shared with the
// one asking.
LAST_SEEN_HIDDEN :: max(Unix_Ms)

// How many accounts one Last_Seen asks about.
MAX_LAST_SEEN :: 256

BUDDY_SET_SIZE :: 4 + 1
LAST_SEEN_ENTRY_SIZE :: 4 + 8

// A Buddy_Set request, or a Buddy_Changed event.
encode_buddy :: proc(out: ^[BUDDY_SET_SIZE]u8, account: Account_Id, on: bool) -> []u8 {
	w := Writer {
		buf = out[:],
	}
	put_u32(&w, u32(account))
	put_u8(&w, u8(on))
	return out[:]
}

decode_buddy :: proc(body: []u8) -> (account: Account_Id, on: bool, ok: bool) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	on = get_u8(&r) != 0
	return account, on, !r.overflow && account != 0
}

// encode_last_seen_ask writes a Last_Seen request: as many of `accounts`
// as one may ask about.
encode_last_seen_ask :: proc(out: []u8, accounts: []Account_Id) -> []u8 {
	w := Writer {
		buf = out,
	}
	count := min(len(accounts), MAX_LAST_SEEN, (len(out) - 2) / 4)
	put_u16(&w, u16(count))
	for a in accounts[:count] {
		put_u32(&w, u32(a))
	}
	return nil if w.overflow else out[:w.pos]
}

decode_last_seen_ask :: proc(body: []u8, buf: []Account_Id) -> (accounts: []Account_Id, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(buf) || count > MAX_LAST_SEEN {
		return
	}
	for &a in buf[:count] {
		a = Account_Id(get_u32(&r))
	}
	if r.overflow {
		return
	}
	return buf[:count], true
}

Last_Seen_Entry :: struct {
	account: Account_Id,
	time:    Unix_Ms, // or 0, or LAST_SEEN_HIDDEN
}

// encode_last_seen_answer writes a Last_Seen response.
encode_last_seen_answer :: proc(out: []u8, entries: []Last_Seen_Entry) -> []u8 {
	w := Writer {
		buf = out,
	}
	count := min(len(entries), MAX_LAST_SEEN, (len(out) - 2) / LAST_SEEN_ENTRY_SIZE)
	put_u16(&w, u16(count))
	for e in entries[:count] {
		put_u32(&w, u32(e.account))
		put_u64(&w, u64(e.time))
	}
	return nil if w.overflow else out[:w.pos]
}

decode_last_seen_answer :: proc(body: []u8, buf: []Last_Seen_Entry) -> (entries: []Last_Seen_Entry, ok: bool) {
	r := Reader {
		buf = body,
	}
	count := int(get_u16(&r))
	if r.overflow || count > len(buf) {
		return
	}
	for &e in buf[:count] {
		e.account = Account_Id(get_u32(&r))
		e.time = Unix_Ms(get_u64(&r))
	}
	if r.overflow {
		return
	}
	return buf[:count], true
}
