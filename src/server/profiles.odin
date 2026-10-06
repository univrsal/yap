package server

import "core:log"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

/*
What a person says about themselves (src/common/proto/accounts.odin):
their display name, a status that may end by itself, and a picture; and
the settings their clients keep here (src/common/proto/settings.odin).

A status that ends is cleared by the loop (profiles_sync) within a
second of its time, also one that ended while the server was down.

A picture is a blob, uploaded first like a message's (transfers.odin) as
kind Avatar: a JPEG at most MAX_AVATAR_SIDE pixels a side. Anyone
logged in may fetch a blob that is someone's picture.

Settings are kept as they come, by key, and not looked inside.
*/

// How often statuses are looked at for ones that have ended.
STATUS_CHECK :: time.Second

/*
email_set sets the asking account's email address (Email_Set): one that
could be one (proto.email_clean) and no other account's, or none.
*/
email_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw, ok := proto.decode_email_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	r := s.registration
	if raw == "" && (r.require_email || r.verify_email) && .Owner not_in acc.flags {
		respond(u, id, .Invalid) // this server wants one
		return
	}
	email := ""
	if raw != "" {
		buf: [proto.MAX_EMAIL_SIZE]u8
		email, ok = proto.email_clean(raw, &buf)
		if !ok {
			respond(u, id, .Invalid)
			return
		}
		email = strings.clone(email, context.temp_allocator)
	}
	if email == acc.email {
		respond(u, id, .Ok)
		return
	}
	if other := account_by_email(&s.accounts, email); other != nil {
		respond(u, id, .Conflict)
		return
	}
	if !account_set_email(&s.accounts, acc, email) {
		respond(u, id, .Internal)
		return
	}
	log.infof("%s %s their email address", conn_label(u), "changed" if email != "" else "removed")
	// A new address has to be verified, as a registration's does; but
	// the owner is never locked out (verify.odin).
	if email != "" && verify_on(s) && .Owner not_in acc.flags {
		by := acc.verify_expires if .Unverified in acc.flags else 0
		if !account_unverify(s, acc, by) {
			respond(u, id, .Internal)
			return
		}
	}
	// Only its own connections know it.
	for c in acc.conns {
		send_self(c)
	}
	respond(u, id, .Ok)
}

profile_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	p, ok := proto.decode_profile_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	// Checked first, so a request is done entirely or not at all.
	name_buf: [proto.MAX_NAME_SIZE]u8
	display := proto.sanitize_name(p.display, &name_buf)
	status_buf: [proto.MAX_STATUS_SIZE]u8
	status := proto.sanitize_text(p.status, status_buf[:])
	until := i64(p.status_until) if status != "" else 0
	if p.mask & proto.PROFILE_DISPLAY != 0 && display == "" {
		respond(u, id, .Invalid)
		return
	}
	if p.mask & proto.PROFILE_AVATAR != 0 && p.avatar != 0 {
		if status := avatar_ok(s, p.avatar); status != .Ok {
			respond(u, id, status)
			return
		}
	}

	changed := false
	if p.mask & proto.PROFILE_DISPLAY != 0 && display != acc.display {
		if !account_set_display(&s.accounts, acc, display) {
			respond(u, id, .Internal)
			return
		}
		log.infof("%s is now called %q", conn_label(u), display)
		changed = true
	}
	if p.mask & proto.PROFILE_STATUS != 0 && (status != acc.status || until != acc.status_until) {
		if !account_set_status(&s.accounts, acc, status, until) {
			respond(u, id, .Internal)
			return
		}
		log.debugf("%s set their status", conn_label(u))
		changed = true
	}
	if p.mask & proto.PROFILE_AVATAR != 0 && p.avatar != acc.avatar {
		if !account_set_avatar(&s.accounts, acc, p.avatar) {
			respond(u, id, .Internal)
			return
		}
		log.debugf("%s changed their picture", conn_label(u))
		changed = true
	}
	if changed {
		account_changed(s, acc)
	}
	respond(u, id, .Ok)
}

// avatar_ok is whether a blob may be somebody's picture: a stored JPEG,
// small enough.
@(private = "file")
avatar_ok :: proc(s: ^Server, blob: proto.Blob_Id) -> proto.Status {
	b, found := blob_get(&s.blobs, blob)
	switch {
	case !found:
		return .Not_Found
	case b.kind != .Avatar && b.kind != .Image:
		return .Invalid
	case b.size > proto.MAX_AVATAR_SIZE ||
	     b.width > proto.MAX_AVATAR_SIDE ||
	     b.height > proto.MAX_AVATAR_SIDE:
		return .Too_Large
	}
	return .Ok
}

// is_avatar is whether a blob is somebody's picture, which anyone may
// fetch.
is_avatar :: proc(s: ^Server, blob: proto.Blob_Id) -> bool {
	for _, acc in s.accounts.by_id {
		if acc.avatar == blob {
			return true
		}
	}
	return false
}

account_set_status :: proc(a: ^Accounts, acc: ^Account, status: string, until: i64) -> bool {
	q := db_stmt(a.db, .Account_Set_Status)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_text(q, 2, status)
	db_bind_int(q, 3, until)
	db_run(a.db, q) or_return
	delete(acc.status)
	acc.status = strings.clone(status)
	acc.status_until = until
	return true
}

account_set_avatar :: proc(a: ^Accounts, acc: ^Account, avatar: proto.Blob_Id) -> bool {
	q := db_stmt(a.db, .Account_Set_Avatar)
	db_bind_int(q, 1, i64(acc.id))
	if avatar == 0 {
		db_bind_null(q, 2)
	} else {
		db_bind_int(q, 2, i64(avatar))
	}
	db_run(a.db, q) or_return
	acc.avatar = avatar
	return true
}

// profiles_sync clears the statuses whose time has come, and tells
// everyone. Called every turn of the loop; looks once a second.
profiles_sync :: proc(s: ^Server) {
	if s.status_checked != {} && time.tick_since(s.status_checked) < STATUS_CHECK {
		return
	}
	s.status_checked = time.tick_now()
	statuses_expire(s, unix_ms())
}

// statuses_expire clears the statuses that have ended by `now`.
statuses_expire :: proc(s: ^Server, now: i64) {
	for _, acc in s.accounts.by_id {
		if acc.status_until == 0 || acc.status_until > now {
			continue
		}
		if account_set_status(&s.accounts, acc, "", 0) {
			account_changed(s, acc)
		}
	}
}

setting_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	key, value, ok := proto.decode_setting(body)
	switch {
	case !ok || !proto.setting_key_ok(key):
		respond(u, id, .Invalid)
		return
	case len(value) > proto.MAX_SETTING_VALUE:
		respond(u, id, .Too_Large)
		return
	}
	acc := u.account
	if len(value) == 0 {
		q := db_stmt(&s.db, .Setting_Delete)
		db_bind_int(q, 1, i64(acc.id))
		db_bind_text(q, 2, key)
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
	} else {
		if !setting_exists(s, acc, key) && setting_count(s, acc) >= proto.MAX_SETTINGS {
			respond(u, id, .Too_Large)
			return
		}
		q := db_stmt(&s.db, .Setting_Put)
		db_bind_int(q, 1, i64(acc.id))
		db_bind_text(q, 2, key)
		db_bind_blob(q, 3, value)
		if !db_run(&s.db, q) {
			respond(u, id, .Internal)
			return
		}
	}
	respond(u, id, .Ok)
	// The account's other connections.
	buf: [proto.SETTING_MAX_SIZE]u8
	event := proto.encode_setting(buf[:], key, value)
	for other in acc.conns {
		if other != u {
			send_event(other, .Setting_Changed, event)
		}
	}
}

@(private = "file")
setting_exists :: proc(s: ^Server, acc: ^Account, key: string) -> bool {
	q := db_stmt(&s.db, .Setting_Has)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_text(q, 2, key)
	row, _ := db_step(&s.db, q)
	sqlite.reset(q)
	return row
}

@(private = "file")
setting_count :: proc(s: ^Server, acc: ^Account) -> int {
	q := db_stmt(&s.db, .Setting_Count)
	db_bind_int(q, 1, i64(acc.id))
	row, _ := db_step(&s.db, q)
	n := int(db_col_int(q, 0)) if row else 0
	sqlite.reset(q)
	return n
}

// send_settings tells a connection that just logged in its account's
// settings (directory_sync).
send_settings :: proc(s: ^Server, u: ^Conn) {
	q := db_stmt(&s.db, .Setting_All)
	db_bind_int(q, 1, i64(u.account.id))
	buf: [proto.SETTING_MAX_SIZE]u8
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		key := db_col_text(q, 0)
		value := db_col_blob(q, 1)
		send_event(u, .Setting_Changed, proto.encode_setting(buf[:], key, value))
	}
}
