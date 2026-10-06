package server

import "core:log"
import "core:strings"

import "common:proto"
import "sqlite"

/*
Invite codes (proto/register.odin): made by whoever has Create_Invites,
good for some number of registrations (or any), until some time (or
none), or until revoked. They stay in the database once used up, so who
made a code and who registered with it are both known (invite_uses),
and with Manage_Accounts can be asked (Invite_Of).

A deleted account's codes are revoked with it (Invite_Erase).
*/

// How many usable codes one account may have at once.
INVITES_LIVE_MOST :: 50

// invite_get reads an invite; the code is in the temp allocator.
invite_get :: proc(db: ^DB, code: string) -> (inv: proto.Invite, found: bool) {
	q := db_stmt(db, .Invite_Get)
	db_bind_text(q, 1, code)
	row, ok := db_step(db, q)
	if !ok || !row {
		return
	}
	// One row: done with it, or it holds a read open (db_step).
	defer sqlite.reset(q)
	return invite_row(q), true
}

@(private = "file")
invite_row :: proc(q: ^sqlite.Stmt) -> proto.Invite {
	return {
		code = db_col_text(q, 0),
		creator = proto.Account_Id(db_col_int(q, 1)),
		created = proto.Unix_Ms(db_col_int(q, 2)),
		max_uses = u16(db_col_int(q, 3)),
		uses = u16(db_col_int(q, 4)),
		expires = proto.Unix_Ms(db_col_int(q, 5)),
		revoked = db_col_int(q, 6) != 0,
	}
}

// invite_use counts a registration against a code, and keeps who it was.
invite_use :: proc(db: ^DB, code: string, account: proto.Account_Id) -> bool {
	q := db_stmt(db, .Invite_Use)
	db_bind_text(q, 1, code)
	db_run(db, q) or_return
	q = db_stmt(db, .Invite_Use_Add)
	db_bind_text(q, 1, code)
	db_bind_int(q, 2, i64(account))
	db_bind_int(q, 3, unix_ms())
	return db_run(db, q)
}

invite_create :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	max_uses, expires, ok := proto.decode_invite_create(body)
	now := unix_ms()
	switch {
	case !can(u.account, .Create_Invites):
		respond(u, id, .Denied)
		return
	case !ok || max_uses > proto.MAX_INVITE_USES || (expires != 0 && i64(expires) <= now):
		respond(u, id, .Invalid)
		return
	}
	q := db_stmt(&s.db, .Invite_Live_Count)
	db_bind_int(q, 1, i64(u.account.id))
	db_bind_int(q, 2, now)
	row, counted := db_step(&s.db, q)
	if !counted || !row {
		respond(u, id, .Internal)
		return
	}
	live := db_col_int(q, 0)
	sqlite.reset(q)
	if live >= INVITES_LIVE_MOST {
		respond(u, id, .Too_Large)
		return
	}

	code_buf: [proto.INVITE_CODE_SIZE]u8
	code: string
	for _ in 0 ..< 8 {
		code = invite_code_new(&code_buf)
		if _, taken := invite_get(&s.db, code); !taken {
			break
		}
		code = ""
	}
	if code == "" {
		respond(u, id, .Internal)
		return
	}
	q = db_stmt(&s.db, .Invite_Add)
	db_bind_text(q, 1, code)
	db_bind_int(q, 2, i64(u.account.id))
	db_bind_int(q, 3, now)
	db_bind_int(q, 4, i64(max_uses))
	db_bind_int(q, 5, i64(expires))
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s made an invite code (%d uses, expiring %d)", conn_label(u), max_uses, expires)
	out: [1 + proto.INVITE_CODE_SIZE]u8
	respond(u, id, .Ok, proto.encode_invite_code(&out, code))
}

// invite_list lists one's own codes, or with Manage_Accounts everybody's.
invite_list :: proc(s: ^Server, u: ^Conn, id: u32) {
	all := can(u.account, .Manage_Accounts)
	if !all && !can(u.account, .Create_Invites) {
		respond(u, id, .Denied)
		return
	}
	q := db_stmt(&s.db, .Invite_All if all else .Invite_Mine)
	db_bind_int(q, 1, proto.MAX_INVITES_LISTED)
	if !all {
		db_bind_int(q, 2, i64(u.account.id))
	}
	invites := make([dynamic]proto.Invite, context.temp_allocator)
	for {
		row, ok := db_step(&s.db, q)
		if !ok {
			respond(u, id, .Internal)
			return
		}
		if !row {
			break
		}
		append(&invites, invite_row(q))
	}
	out := make([]u8, 2 + len(invites) * proto.INVITE_MAX_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_invites(out, invites[:]))
}

invite_revoke :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw, ok := proto.decode_invite_code(body)
	buf: [proto.INVITE_CODE_SIZE]u8
	code, clean := proto.invite_code_clean(raw, &buf)
	if !ok || !clean {
		respond(u, id, .Invalid)
		return
	}
	inv, found := invite_get(&s.db, code)
	switch {
	case !found:
		respond(u, id, .Not_Found)
		return
	case inv.creator != u.account.id && !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	}
	q := db_stmt(&s.db, .Invite_Revoke)
	db_bind_text(q, 1, code)
	if !db_run(&s.db, q) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s revoked the invite code %s", conn_label(u), code)
	respond(u, id, .Ok)
}

// invite_of is the code an account registered with, for whoever
// manages accounts.
invite_of :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	account, ok := proto.decode_account_id(body)
	switch {
	case !can(u.account, .Manage_Accounts):
		respond(u, id, .Denied)
		return
	case !ok:
		respond(u, id, .Invalid)
		return
	}
	q := db_stmt(&s.db, .Invite_Of)
	db_bind_int(q, 1, i64(account))
	row, stepped := db_step(&s.db, q)
	switch {
	case !stepped:
		respond(u, id, .Internal)
	case !row:
		respond(u, id, .Not_Found)
	case:
		out: [proto.INVITE_OF_SIZE]u8
		code := strings.clone(db_col_text(q, 0), context.temp_allocator)
		creator := proto.Account_Id(db_col_int(q, 1))
		sqlite.reset(q)
		respond(u, id, .Ok, proto.encode_invite_of(&out, code, creator))
	}
}
