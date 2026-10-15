package server

import "core:log"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

// Profiles are what a person says about themselves (see
// src/common/proto/accounts.odin): a display name, a status that can expire
// automatically and a picture. This file also handles the settings that a
// person's clients store on the server (see src/common/proto/settings.odin).
//
// A status that expires is cleared by the main loop (profiles_sync) within a
// second of its end time. This includes statuses that expired while the
// server was down.
//
// A picture is a blob of kind Avatar. It is uploaded first, like a message
// attachment (see transfers.odin), and must be a JPEG with at most
// MAX_AVATAR_SIDE pixels per side. Anyone who is logged in may fetch a blob
// that is somebody's picture.
//
// Settings are stored by key and the server doesn't look at their values.
// The only exception is proto.SETTING_EMAIL_DIGEST, which must be one of the
// valid digest values and of which the server keeps a copy in the account
// (see digest.odin).

// How often the statuses are checked for ones that have expired.
STATUS_CHECK :: time.Second

// email_set sets the email address of the requesting account (Email_Set).
// The address must be a valid email address (see proto.email_clean) that
// no other account uses. An empty address removes the email address.
email_set :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	raw, ok := proto.decode_email_set(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	acc := u.account
	r := s.registration
	if raw == "" && (r.require_email || r.verify_email) && .Owner not_in acc.flags {
		respond(u, id, .Invalid) // this server requires an email address
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
	// A new address has to be verified, just like the address given when
	// registering. The owner is never locked out for that (see verify.odin).
	if email != "" && verify_on(s) && .Owner not_in acc.flags {
		by := acc.verify_expires if .Unverified in acc.flags else 0
		if !account_unverify(s, acc, by) {
			respond(u, id, .Internal)
			return
		}
	}
	// Only the account's own connections are told about the new address.
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
	// Everything is validated first so that a request is either applied
	// entirely or not at all.
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

// avatar_ok checks whether a blob can be used as somebody's picture, i.e.
// it is a stored JPEG that is small enough.
@(private = "file")
avatar_ok :: proc(s: ^Server, blob: proto.Blob_Id) -> proto.Status {
	b, found := blob_get(&s.blobs, blob)
	switch {
	case !found:
		return .Not_Found
	case b.kind != .Avatar:
		return .Invalid
	case b.size > proto.MAX_AVATAR_SIZE ||
	     b.width > proto.MAX_AVATAR_SIDE ||
	     b.height > proto.MAX_AVATAR_SIDE:
		return .Too_Large
	}
	return .Ok
}

// is_avatar returns whether a blob is somebody's picture, which anyone may
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

// profiles_sync clears the statuses that have expired and notifies everyone.
// It is called on every iteration of the main loop but only checks once a
// second.
profiles_sync :: proc(s: ^Server) {
	if s.status_checked != {} && time.tick_since(s.status_checked) < STATUS_CHECK {
		return
	}
	s.status_checked = time.tick_now()
	statuses_expire(s, unix_ms())
}

// statuses_expire clears the statuses that have expired by `now`.
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
	// This is the only setting the server reads itself (see digest.odin).
	digest: proto.Email_Digest
	if key == proto.SETTING_EMAIL_DIGEST {
		digest, ok = proto.email_digest_parse(string(value))
		if !ok {
			respond(u, id, .Invalid)
			return
		}
	}
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
	switch key {
	case proto.SETTING_EMAIL_DIGEST:
		acc.digest = digest
	case proto.SETTING_PUSH_TEXT:
		acc.push_hide = string(value) == proto.PUSH_TEXT_HIDDEN
	}
	respond(u, id, .Ok)
	// Notify the account's other connections.
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

// send_settings sends the settings of the account to a connection that
// just logged in (see directory_sync).
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
