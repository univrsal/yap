package server

import "core:log"

import "common:proto"

/*
Activity (src/common/proto/activity.odin): online, away, busy or
offline, as everyone sees it, worked out from what the account chose
(kept in the database, so it's the same on every device and after a
restart) and whether its connections' users are idle:

	no connection, or chose Offline   Offline
	chose Busy, or Away               that
	chose Online                      Away if every connection is idle,
	                                  else Online

It's in the account's record, so a change goes to everyone as
Account_Changed (activity_check). An account that chose to appear
offline is also left out of who is here for everyone but itself, while
its voice isn't in a room they can see (sync_state).
*/

// activity_of is how everyone sees an account.
activity_of :: proc(acc: ^Account) -> proto.Activity {
	if len(acc.conns) == 0 || acc.chosen == .Offline {
		return .Offline
	}
	if acc.chosen != .Online {
		return acc.chosen
	}
	for u in acc.conns {
		if !u.idle {
			return .Online
		}
	}
	return .Away
}

// appears_offline is whether an account is hidden from who is here.
appears_offline :: proc(acc: ^Account) -> bool {
	return acc.chosen == .Offline
}

// activity_check tells everyone when how an account is seen has changed:
// after it comes or goes, chooses, or its users go idle or come back.
activity_check :: proc(s: ^Server, acc: ^Account) {
	now := activity_of(acc)
	if now == acc.shown {
		return
	}
	acc.shown = now
	account_told(s, acc)
}

activity_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	chosen, ok := proto.decode_activity(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	if chosen != acc.chosen {
		q := db_stmt(&s.db, .Account_Set_Activity)
		db_bind_int(q, 1, i64(acc.id))
		db_bind_int(q, 2, i64(chosen))
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
		was_hidden := appears_offline(acc)
		acc.chosen = chosen
		log.debugf("%s is %v now", conn_label(u), chosen)
		// Its own connections are told what it chose (Self), and it may
		// show or hide in who is here.
		if was_hidden != appears_offline(acc) {
			bump_version(s)
		}
		acc.shown = activity_of(acc)
		account_changed(s, acc)
	}
	respond(u, id, .Ok)
}

idle_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	idle, ok := proto.decode_idle(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if idle != u.idle {
		log.debugf("%s is %s", conn_label(u), "idle" if idle else "back")
	}
	u.idle = idle
	respond(u, id, .Ok)
	activity_check(s, u.account)
}
