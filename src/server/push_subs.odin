package server

import "core:log"

import "common:proto"
import "sqlite"

// Web Push subscriptions (src/common/proto/push.odin): the subscriptions that browsers
// with push enabled sent to the server, so push.odin can reach them.
//
// They are only stored in the database (push_subs). Each one belongs to a device, and each
// device has at most one: a new subscription replaces the previous one. The table's
// foreign key deletes a subscription together with its device (on logout, revocation or
// account deletion). Subscriptions that a push service reports as permanently gone are
// deleted as well (push_sync).

// A subscription, as returned by push_subs_of.
Push_Sub :: struct {
	id:       i64,
	endpoint: string,
	p256dh:   [P256_PUBLIC_SIZE]u8,
	auth:     [PUSH_AUTH_SIZE]u8,
	device:   [proto.KEY_SIZE]u8, // the key of the device it belongs to
}

// push_request handles a subscription request; returns false if `op` isn't one.
push_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Push_Subscribe:
		push_subscribe(s, u, id, body)
	case .Push_Unsubscribe:
		push_unsubscribe(s, u, id)
	case:
		return false
	}
	return true
}

@(private = "file")
push_subscribe :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	sub, ok := proto.decode_push_subscribe(body)
	switch {
	case !ok || push_origin(sub.endpoint) == "":
		respond(u, id, .Invalid)
		return
	case !s.push.enabled:
		respond(u, id, .Closed)
		return
	}
	key := u.key
	q := db_query(
		&s.db,
		.Push_Sub_Put,
		key[:],
		i64(u.account.id),
		sub.endpoint,
		sub.p256dh[:],
		sub.auth[:],
		unix_ms(),
	)
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	q = db_query(&s.db, .Push_Sub_Others, key[:], sub.endpoint)
	_ = db_run(&s.db, q)
	log.debugf("%s enabled push, via %s", conn_label(u), push_origin(sub.endpoint))
	respond(u, id, .Ok)
}

@(private = "file")
push_unsubscribe :: proc(s: ^Server, u: ^Conn, id: u32) {
	key := u.key
	if !db_write(&s.db, .Push_Sub_Drop, key[:]) {
		respond(u, id, .Internal)
		return
	}
	log.debugf("%s disabled push", conn_label(u))
	respond(u, id, .Ok)
}

// push_subs_of returns an account's subscriptions, in the temp allocator.
push_subs_of :: proc(s: ^Server, account: proto.Account_Id) -> []Push_Sub {
	subs := make([dynamic]Push_Sub, context.temp_allocator)
	q := db_query(&s.db, .Push_Subs_Of, i64(account))
	for {
		row, ok := db_step(&s.db, q)
		if !row || !ok {
			break
		}
		sub := Push_Sub {
			id       = db_col_int(q, 0),
			endpoint = db_col_text(q, 1),
		}
		if db_col_into(q, 2, sub.p256dh[:]) &&
		   db_col_into(q, 3, sub.auth[:]) &&
		   db_col_into(q, 4, sub.device[:]) {
			append(&subs, sub)
		}
	}
	sqlite.reset(q)
	return subs[:]
}

// push_sync processes the results of sent pushes: a subscription that the push service
// reports as gone is deleted.
push_sync :: proc(s: ^Server) {
	for {
		r := push_poll(&s.push) or_break
		if r.outcome != .Gone {
			continue
		}
		if db_write(&s.db, .Push_Sub_Gone, r.sub) && db_changed(&s.db) > 0 {
			log.debugf("push: subscription %d no longer exists and was deleted", r.sub)
		}
	}
}
