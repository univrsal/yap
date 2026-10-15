package server

import "core:log"
import "core:slice"

import "common:proto"

// Buddies and when people were last seen (src/common/proto/buddies.odin).
//
// An account's buddy list is private to it. Adding someone as a buddy
// doesn't ask or notify them. The list is stored with the accounts (in
// memory and in the database), and every connection of the account is
// sent the list at login and each change afterwards.
//
// When an account was last seen is stored in accounts.last_seen, which is
// updated when its last connection leaves (account_seen). It is only
// revealed to accounts that have exchanged messages with it, meaning both
// have posted in the DM between them. Whether an account is connected
// right now is visible to everyone in the snapshot, so that is not hidden.

// buddy_request handles a request about buddies or when people were
// last seen. It returns false if `op` isn't one of those.
buddy_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Buddy_Set:
		buddy_set(s, u, id, body)
	case .Last_Seen:
		last_seen(s, u, id, body)
	case:
		return false
	}
	return true
}

// send_buddies sends a connection all the buddies of its account.
send_buddies :: proc(u: ^Conn) {
	for b in u.account.buddies {
		buf: [proto.BUDDY_SET_SIZE]u8
		send_event(u, .Buddy_Changed, proto.encode_buddy(&buf, b, true))
	}
}

@(private = "file")
buddy_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	other, on, ok := proto.decode_buddy(body)
	acc := u.account
	switch {
	case !ok || other == acc.id:
		respond(u, id, .Invalid)
		return
	case account_live(&s.accounts, other) == nil:
		respond(u, id, .Not_Found)
		return
	}
	i, has := slice.linear_search(acc.buddies[:], other)
	if on == has {
		respond(u, id, .Ok)
		return
	}
	q := db_stmt(&s.db, .Buddy_Add if on else .Buddy_Remove)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_int(q, 2, i64(other))
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	if on {
		append(&acc.buddies, other)
	} else {
		ordered_remove(&acc.buddies, i)
	}
	log.debugf("%s %s account %d as a buddy", conn_label(u), "added" if on else "removed", other)
	respond(u, id, .Ok)
	// Tell every device of the account, including the one that asked,
	// because each device relies on this event to update its list.
	buf: [proto.BUDDY_SET_SIZE]u8
	changed := proto.encode_buddy(&buf, other, on)
	for c in acc.conns {
		send_event(c, .Buddy_Changed, changed)
	}
}

@(private = "file")
last_seen :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	buf: [proto.MAX_LAST_SEEN]proto.Account_Id
	asked, ok := proto.decode_last_seen_ask(body, buf[:])
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	entries := make([]proto.Last_Seen_Entry, len(asked), context.temp_allocator)
	now := proto.Unix_Ms(unix_ms())
	for account, i in asked {
		entries[i] = {
			account = account,
			time    = last_seen_by(s, u.account, account, now),
		}
	}
	out := make([]u8, 2 + len(entries) * proto.LAST_SEEN_ENTRY_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_last_seen_answer(out, entries))
}

// last_seen_by returns when `account` was last seen, as far as `asker`
// is allowed to know.
last_seen_by :: proc(
	s: ^Server,
	asker: ^Account,
	account: proto.Account_Id,
	now: proto.Unix_Ms,
) -> proto.Unix_Ms {
	acc := account_by_id(&s.accounts, account)
	switch {
	case acc == nil:
		return 0
	case len(acc.conns) > 0 && !appears_offline(acc):
		return now // connected, which anyone can see anyway
	case len(acc.conns) > 0 && acc.id != asker.id && !messages_exchanged(s, asker.id, account):
		return proto.LAST_SEEN_HIDDEN
	case len(acc.conns) > 0:
		// Appearing offline, so report when it was last seen connected.
		return proto.Unix_Ms(acc.last_seen)
	case !messages_exchanged(s, asker.id, account):
		return proto.LAST_SEEN_HIDDEN
	}
	return proto.Unix_Ms(acc.last_seen)
}

// messages_exchanged is whether two accounts have both posted in the
// DM between them.
messages_exchanged :: proc(s: ^Server, x, y: proto.Account_Id) -> bool {
	conv := dm_find(&s.convs, x, y)
	return conv != nil && dm_posted(&s.convs, conv, x) && dm_posted(&s.convs, conv, y)
}
