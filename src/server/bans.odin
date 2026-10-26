package server

import "core:log"
import "core:slice"
import "core:strings"

import "common:proto"

// Bans (proto/moderation.odin, docs/design/moderation.md D9): a ban is a
// disabled account with a record of who banned it, when and why, and the
// email address it had then. All of them are kept in memory, like the
// accounts, and in the bans table.
//
// While an account is banned:
//   - it is Disabled, so it can't log in or be logged in by a device;
//   - a known device of it that connects is told Logged_Out(Banned) with the
//     reason (auth_known_device), and a login with the right password is
//     answered Status.Banned with the reason (login_finish), never a wrong
//     one, so the reason isn't told to whoever guesses a username;
//   - its email address can't be used to register or be taken by another
//     account, with the same answer as for an address that is in use.
//
// Unbanning removes the record and enables the account. Enabling it with
// Account_Disable removes the record too, so the two can't disagree.

Ban_Record :: struct {
	by:     proto.Account_Id,
	time:   proto.Unix_Ms,
	reason: string, // owned
	email:  string, // owned; lower case, or "" for none
}

// bans_load reads the bans from the database (accounts_load).
@(require_results)
bans_load :: proc(a: ^Accounts) -> bool {
	q := db_stmt(a.db, .Ban_All)
	for {
		row, ok := db_step(a.db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		a.bans[proto.Account_Id(db_col_int(q, 0))] = {
			by     = proto.Account_Id(db_col_int(q, 1)),
			time   = proto.Unix_Ms(db_col_int(q, 2)),
			reason = db_col_text(q, 3, context.allocator),
			email  = db_col_text(q, 4, context.allocator),
		}
	}
	return true
}

bans_destroy :: proc(a: ^Accounts) {
	for _, b in a.bans {
		ban_record_destroy(b)
	}
	delete(a.bans)
}

@(private = "file")
ban_record_destroy :: proc(b: Ban_Record) {
	delete(b.reason)
	delete(b.email)
}

// ban_of returns the ban of an account, if it is banned.
ban_of :: proc(a: ^Accounts, account: proto.Account_Id) -> (Ban_Record, bool) {
	return a.bans[account]
}

// ban_reason returns the reason an account was banned for, if it is.
ban_reason :: proc(a: ^Accounts, account: proto.Account_Id) -> (reason: string, banned: bool) {
	b := ban_of(a, account) or_return
	return b.reason, true
}

// email_banned is whether a (lower case) email address is that of a banned
// account, and so can't be used by any account.
email_banned :: proc(a: ^Accounts, email: string) -> bool {
	if email == "" {
		return false
	}
	for _, b in a.bans {
		if b.email == email {
			return true
		}
	}
	return false
}

// ban_add records a ban of `acc` by `by`, or replaces its record. `reason`
// must be sanitized.
@(require_results)
ban_add :: proc(a: ^Accounts, acc: ^Account, by: proto.Account_Id, reason: string) -> bool {
	now := unix_ms()
	db_write(a.db, .Ban_Add, i64(acc.id), i64(by), now, reason, acc.email) or_return
	if old, ok := a.bans[acc.id]; ok {
		ban_record_destroy(old)
	}
	a.bans[acc.id] = {
		by     = by,
		time   = proto.Unix_Ms(now),
		reason = strings.clone(reason),
		email  = strings.clone(acc.email),
	}
	return true
}

// ban_remove removes the ban of an account, if it has one.
@(require_results)
ban_remove :: proc(a: ^Accounts, account: proto.Account_Id) -> bool {
	old, ok := a.bans[account]
	if !ok {
		return true
	}
	db_write(a.db, .Ban_Remove, i64(account)) or_return
	ban_record_destroy(old)
	delete_key(&a.bans, account)
	return true
}

// ban_set bans or unbans an account (Ban_Set).
ban_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	b, ok := proto.decode_ban_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if !b.on {
		unban(s, u, id, b.account)
		return
	}
	// Removing their messages comes with phase 6 of the plan.
	if b.purge != .None {
		respond(u, id, .Invalid)
		return
	}
	target, status := moderation_target(s, u, b.account, .Ban_Members)
	if target == nil {
		respond(u, id, status)
		return
	}
	buf: [proto.MAX_BAN_REASON]u8
	reason := proto.sanitize_text(b.reason, buf[:])
	if !ban_add(&s.accounts, target, u.account.id, reason) ||
	   !account_set_flags(&s.accounts, target, target.flags + {.Disabled}) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s banned %s (%q)", conn_label(u), target.username, reason)
	respond(u, id, .Ok)
	conns := make([dynamic]^Conn, context.temp_allocator)
	append(&conns, ..target.conns[:])
	for other in conns {
		conn_logout(s, other, .Banned, reason)
	}
	account_changed(s, target)
}

// unban ends the ban of an account and enables it again. A deleted account
// can be unbanned too, which frees the email address it had.
@(private = "file")
unban :: proc(s: ^Server, u: ^Conn, id: u32, account: proto.Account_Id) {
	target := account_by_id(&s.accounts, account)
	_, banned := ban_of(&s.accounts, account)
	switch {
	case !can(u.account, .Ban_Members):
		respond(u, id, .Denied)
		return
	case target == nil || !banned:
		respond(u, id, .Not_Found)
		return
	case !outranks(u.account, permissions(target)):
		respond(u, id, .Denied)
		return
	}
	if !ban_remove(&s.accounts, account) {
		respond(u, id, .Internal)
		return
	}
	live := .Deleted not_in target.flags
	if live && !account_set_flags(&s.accounts, target, target.flags - {.Disabled}) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s unbanned %s", conn_label(u), target.username)
	respond(u, id, .Ok)
	if live {
		account_changed(s, target)
	}
}

// ban_list answers with the bans, newest first (Ban_List).
ban_list :: proc(s: ^Server, u: ^Conn, id: u32) {
	if !can(u.account, .Ban_Members) {
		respond(u, id, .Denied)
		return
	}
	bans := make([dynamic]proto.Ban, 0, len(s.accounts.bans), context.temp_allocator)
	for account, b in s.accounts.bans {
		append(&bans, proto.Ban{account = account, by = b.by, time = b.time, reason = b.reason})
	}
	slice.sort_by(bans[:], proc(x, y: proto.Ban) -> bool {
		return x.time > y.time if x.time != y.time else x.account > y.account
	})
	buf := make([]u8, proto.MAX_BODY_SIZE, context.temp_allocator)
	respond(u, id, .Ok, proto.encode_bans(buf, bans[:]))
}
