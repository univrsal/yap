package server

import "core:log"

import "common:proto"

// Activity (src/common/proto/activity.odin): online, away, busy or
// offline, as everyone sees it. It is derived from the activity the
// account chose (stored in the database, so it is the same on every
// device and after a restart) and whether the users of its connections
// are idle:
//
//	no connection, or chose Offline   Offline
//	chose Busy, or Away               the chosen activity
//	chose Online                      Away if every connection is idle,
//	                                  else Online
//
// The activity is part of the account's record, so a change is sent to
// everyone as Account_Changed (see activity_check). An account that chose
// to appear offline is also left out of the list of who is here for
// everyone but itself, unless it is in a voice room they can see
// (see sync_state).

// activity_of returns the activity everyone sees for an account.
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

// appears_offline is whether an account is hidden from the list of who
// is here.
appears_offline :: proc(acc: ^Account) -> bool {
	return acc.chosen == .Offline
}

// activity_check tells everyone when the activity shown for an account
// has changed, for example after it connects or disconnects, chooses a
// different activity or when its users go idle or come back.
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
	// An activity copied from another server (one that says when it was
	// chosen) only replaces an older one.
	at := i64(proto.decode_activity_at(body))
	if at == 0 {
		at = unix_ms()
	} else if at <= acc.chosen_at {
		respond(u, id, .Ok)
		return
	}
	if chosen != acc.chosen {
		q := db_stmt(&s.db, .Account_Set_Activity)
		db_bind_int(q, 1, i64(acc.id))
		db_bind_int(q, 2, i64(chosen))
		db_bind_int(q, 3, at)
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
		was_hidden := appears_offline(acc)
		acc.chosen, acc.chosen_at = chosen, at
		log.debugf("%s is %v now", conn_label(u), chosen)
		// The account's own connections are told what it chose (Self),
		// and it may appear or disappear in the list of who is here.
		if was_hidden != appears_offline(acc) {
			bump_version(s)
		}
		acc.shown = activity_of(acc)
		account_changed(s, acc)
	}
	respond(u, id, .Ok)
}

idle_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	idle, hidden, ok := proto.decode_idle(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if idle != u.idle {
		log.debugf("%s is %s", conn_label(u), "idle" if idle else "back")
	}
	u.idle = idle
	u.hidden = hidden
	respond(u, id, .Ok)
	activity_check(s, u.account)
}
