package server

import "core:log"

import "common:proto"
import "sqlite"

/*
Web Push subscriptions (src/common/proto/push.odin): what browsers that
turned push on gave the server, so push.odin can reach them.

They're in the database only (push_subs), each a device's: one each, a
new one taking the place of the last, and gone with the device (logging
out, revoking it, deleting the account) by the table's foreign key.
What a push service says is gone for good (push_sync) is forgotten.
*/

// A subscription, as push_subs_of gives them.
Push_Sub :: struct {
	id:       i64,
	endpoint: string,
	p256dh:   [P256_PUBLIC_SIZE]u8,
	auth:     [PUSH_AUTH_SIZE]u8,
	device:   [proto.KEY_SIZE]u8, // whose it is
}

// push_request handles a request about subscriptions; false if `op`
// isn't one.
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
	q := db_stmt(&s.db, .Push_Sub_Put)
	db_bind_blob(q, 1, key[:])
	db_bind_int(q, 2, i64(u.account.id))
	db_bind_text(q, 3, sub.endpoint)
	db_bind_blob(q, 4, sub.p256dh[:])
	db_bind_blob(q, 5, sub.auth[:])
	db_bind_int(q, 6, unix_ms())
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	q = db_stmt(&s.db, .Push_Sub_Others)
	db_bind_blob(q, 1, key[:])
	db_bind_text(q, 2, sub.endpoint)
	_ = db_run(&s.db, q)
	log.debugf("%s turned push on, at %s", conn_label(u), push_origin(sub.endpoint))
	respond(u, id, .Ok)
}

@(private = "file")
push_unsubscribe :: proc(s: ^Server, u: ^Conn, id: u32) {
	key := u.key
	q := db_stmt(&s.db, .Push_Sub_Drop)
	db_bind_blob(q, 1, key[:])
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	log.debugf("%s turned push off", conn_label(u))
	respond(u, id, .Ok)
}

// push_subs_of is an account's subscriptions, in the temp allocator.
push_subs_of :: proc(s: ^Server, account: proto.Account_Id) -> []Push_Sub {
	subs := make([dynamic]Push_Sub, context.temp_allocator)
	q := db_stmt(&s.db, .Push_Subs_Of)
	db_bind_int(q, 1, i64(account))
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

// push_sync takes in what came of the pushes sent: a subscription the
// push service says is gone is forgotten.
push_sync :: proc(s: ^Server) {
	for {
		r := push_poll(&s.push) or_break
		if r.outcome != .Gone {
			continue
		}
		q := db_stmt(&s.db, .Push_Sub_Gone)
		db_bind_int(q, 1, r.sub)
		if db_run(&s.db, q) && db_changed(&s.db) > 0 {
			log.debugf("push: subscription %d is gone, forgotten", r.sub)
		}
	}
}
