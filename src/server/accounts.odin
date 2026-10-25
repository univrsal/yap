package server

import "core:log"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

// Accounts and the devices logged in to them (src/common/proto/accounts.odin).
// This covers what the database stores about them and the in-memory copy
// the server works from.
//
// There are few accounts and nearly everything needs to look them up
// (for example to find out whose connection this is, or what an account
// is called). They are therefore all read into memory when the server
// starts, and every change is made both in memory and in the database.
// The password hash is the exception: it stays in the database and is
// only fetched when somebody logs in.
//
// Nothing here decides who may do what, and nothing here is slow. This
// file only keeps track of accounts and devices. Logging in and the other
// requests from clients are handled in auth.odin.

Account :: struct {
	id:             proto.Account_Id,
	username:       string, // owned; lower case
	display:        string, // owned
	flags:          proto.Account_Flags,
	// Its status text (owned; "" for none), when the status ends
	// (0 if it never does), when it was set (0 if unknown) and its
	// picture (profiles.odin).
	status:         string,
	status_until:   i64,
	status_at:      i64,
	avatar:         proto.Blob_Id,
	// Its email address (owned; "" for none). It is lower case and no
	// other account has the same one. Only the account itself is told it.
	email:          string,
	// While the account is Unverified: the code that must be sent back
	// from the mail (owned) and when the account is deleted if it
	// never is (0 for never). See verify.odin.
	verify_code:    string,
	verify_expires: i64,
	// Which digest mails about missed messages it wants (its setting
	// proto.SETTING_EMAIL_DIGEST), the newest message at the time of the
	// last mail and when that mail was sent, and the newest message at
	// the time it was last checked for a digest (digest.odin).
	digest:         proto.Email_Digest,
	digest_upto:    proto.Msg_Id,
	digest_sent:    i64,
	digest_checked: proto.Msg_Id,
	// Whether its push notifications leave out the text of messages (its
	// setting proto.SETTING_PUSH_TEXT, see push_notify.odin).
	push_hide:      bool,
	// Whether everyone isn't shown that it is talking in a voice room or a
	// call (its setting proto.SETTING_VOICE_SHOWN, see sync_state).
	voice_hidden:   bool,
	// The activity it chose (online, away, busy or offline), when it
	// chose it (0 if unknown), and the activity everyone was last told it
	// has (activity.odin).
	chosen:         proto.Activity,
	chosen_at:      i64,
	shown:          proto.Activity,
	created:        i64, // Unix milliseconds
	last_seen:      i64, // when its last connection left; 0 if it never connected
	// Its current connections, one per connected device.
	conns:          [dynamic]^Conn,
	// The accounts in its buddy list (buddies.odin).
	buddies:        [dynamic]proto.Account_Id,
	// Its roles (other than the one everyone has) and the permissions
	// they grant, recalculated whenever a role or this list changes
	// (roles.odin).
	roles:          [dynamic]proto.Role_Id,
	perms:          proto.Permissions,
	// The number of wrong passwords entered in a row, and the time until
	// which further login attempts are rejected (auth.odin).
	failures:       int,
	locked_until:   time.Tick,
	// How many logins to it are being hashed right now (auth.odin).
	checking:       int,
}

Device :: struct {
	key:       [proto.KEY_SIZE]u8,
	account:   proto.Account_Id,
	name:      string, // owned
	agent:     string, // owned; the user agent the client reported, "" if none
	created:   i64, // when it logged in
	last_seen: i64, // when it last connected
}

Accounts :: struct {
	db:      ^DB,
	roles:   map[proto.Role_Id]^Role, // roles.odin
	by_id:   map[proto.Account_Id]^Account,
	by_name: map[string]^Account, // the key is the account's own username
	devices: map[[proto.KEY_SIZE]u8]^Device,
}

// accounts_load reads all accounts and devices from the database.
@(require_results)
accounts_load :: proc(a: ^Accounts, db: ^DB) -> bool {
	a.db = db
	q := db_stmt(db, .Account_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		acc := new(Account)
		acc.id = proto.Account_Id(db_col_int(q, 0))
		acc.username = db_col_text(q, 1, context.allocator)
		acc.display = db_col_text(q, 2, context.allocator)
		acc.flags = transmute(proto.Account_Flags)u8(db_col_int(q, 3))
		acc.created = db_col_int(q, 4)
		acc.last_seen = db_col_int(q, 5)
		acc.status = db_col_text(q, 6, context.allocator)
		acc.status_until = db_col_int(q, 7)
		acc.avatar = proto.Blob_Id(db_col_int(q, 8))
		if chosen := db_col_int(q, 9); chosen >= 0 && chosen <= i64(max(proto.Activity)) {
			acc.chosen = proto.Activity(chosen)
		}
		acc.email = db_col_text(q, 10, context.allocator)
		acc.verify_code = db_col_text(q, 11, context.allocator)
		acc.verify_expires = db_col_int(q, 12)
		acc.digest_upto = proto.Msg_Id(db_col_int(q, 13))
		acc.digest, _ = proto.email_digest_parse(db_col_text(q, 14))
		acc.push_hide = db_col_text(q, 15) == proto.PUSH_TEXT_HIDDEN
		acc.voice_hidden = db_col_text(q, 16) == proto.VOICE_SHOWN_HIDDEN
		acc.chosen_at = db_col_int(q, 17)
		acc.status_at = db_col_int(q, 18)
		acc.shown = .Offline // nobody is connected yet
		a.by_id[acc.id] = acc
		a.by_name[acc.username] = acc
	}

	q = db_stmt(db, .Device_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		d := new(Device)
		if !db_col_into(q, 0, d.key[:]) {
			log.warn("a device in the database has a key of the wrong size, skipping it")
			free(d)
			continue
		}
		d.account = proto.Account_Id(db_col_int(q, 1))
		d.name = db_col_text(q, 2, context.allocator)
		d.created = db_col_int(q, 3)
		d.last_seen = db_col_int(q, 4)
		d.agent = db_col_text(q, 5, context.allocator)
		a.devices[d.key] = d
	}

	q = db_stmt(db, .Buddy_All)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return false
		}
		if !row {
			break
		}
		acc := a.by_id[proto.Account_Id(db_col_int(q, 0))] or_else nil
		if acc != nil {
			append(&acc.buddies, proto.Account_Id(db_col_int(q, 1)))
		}
	}
	return roles_load(a)
}

accounts_destroy :: proc(a: ^Accounts) {
	for _, acc in a.by_id {
		delete(acc.username)
		delete(acc.display)
		delete(acc.status)
		delete(acc.email)
		delete(acc.verify_code)
		delete(acc.conns)
		delete(acc.buddies)
		delete(acc.roles)
		free(acc)
	}
	for _, d in a.devices {
		delete(d.name)
		delete(d.agent)
		free(d)
	}
	delete(a.by_id)
	delete(a.by_name)
	delete(a.devices)
	roles_destroy(a)
	a^ = {}
}

// account_find returns the account with this username (as returned by
// username_clean), or nil if there is none.
account_find :: proc(a: ^Accounts, username: string) -> ^Account {
	return a.by_name[username] or_else nil
}

account_by_id :: proc(a: ^Accounts, id: proto.Account_Id) -> ^Account {
	return a.by_id[id] or_else nil
}

// account_live returns the account with this id if it exists and isn't
// deleted. Only such accounts can be messaged, called, added as a buddy
// or given a role.
account_live :: proc(a: ^Accounts, id: proto.Account_Id) -> ^Account {
	acc := account_by_id(a, id)
	return acc if acc != nil && .Deleted not_in acc.flags else nil
}

// account_add creates an account. The username must already be cleaned
// (proto.username_clean) and not taken, and the display name must be
// sanitized and not empty. It returns nil if the database rejects it.
@(require_results)
account_add :: proc(
	a: ^Accounts,
	username, display: string,
	secret: Secret,
	flags: proto.Account_Flags,
) -> ^Account {
	if username in a.by_name {
		return nil
	}
	secret := secret
	now := unix_ms()
	if !db_write(
		a.db,
		.Account_Add,
		username,
		display,
		secret.hash[:],
		secret.salt[:],
		i64(secret.params),
		i64(transmute(u8)flags),
		now,
	) {
		return nil
	}
	acc := new(Account)
	acc.id = proto.Account_Id(db_last_id(a.db))
	acc.username = strings.clone(username)
	acc.display = strings.clone(display)
	acc.flags = flags
	acc.created = now
	acc.shown = .Offline // not connected yet (activity.odin)
	a.by_id[acc.id] = acc
	a.by_name[acc.username] = acc
	account_perms_update(a, acc)
	return acc
}

// account_secret fetches an account's stored password hash.
@(require_results)
account_secret :: proc(a: ^Accounts, acc: ^Account) -> (s: Secret, ok: bool) {
	q := db_query(a.db, .Account_Secret, i64(acc.id))
	row, stepped := db_step(a.db, q)
	if !stepped || !row {
		return
	}
	defer sqlite.reset(q)
	if !db_col_into(q, 0, s.hash[:]) || !db_col_into(q, 1, s.salt[:]) {
		log.errorf("the stored password of %s in the database is malformed", acc.username)
		return {}, false
	}
	s.params = int(db_col_int(q, 2))
	return s, true
}

// account_set_password replaces an account's password. `must_change` is
// set when an admin chose the password, so the account's owner has to
// choose a new one.
account_set_password :: proc(
	a: ^Accounts,
	acc: ^Account,
	secret: Secret,
	must_change: bool,
) -> bool {
	secret := secret
	db_write(
		a.db,
		.Account_Set_Password,
		i64(acc.id),
		secret.hash[:],
		secret.salt[:],
		i64(secret.params),
	) or_return
	flags := acc.flags
	if must_change {
		flags += {.Must_Change}
	} else {
		flags -= {.Must_Change}
	}
	acc.failures, acc.locked_until = 0, {}
	return account_set_flags(a, acc, flags)
}

account_set_flags :: proc(a: ^Accounts, acc: ^Account, flags: proto.Account_Flags) -> bool {
	if flags == acc.flags {
		return true
	}
	db_write(a.db, .Account_Set_Flags, i64(acc.id), i64(transmute(u8)flags)) or_return
	acc.flags = flags
	return true
}

// account_set_display changes an account's display name. `display` must
// be sanitized and not empty.
account_set_display :: proc(a: ^Accounts, acc: ^Account, display: string) -> bool {
	db_write(a.db, .Account_Set_Display, i64(acc.id), display) or_return
	delete(acc.display)
	acc.display = strings.clone(display)
	return true
}

// account_by_email returns the account with this (lower case) email
// address, or nil if there is none.
account_by_email :: proc(a: ^Accounts, email: string) -> ^Account {
	if email == "" {
		return nil
	}
	for _, acc in a.by_id {
		if acc.email == email {
			return acc
		}
	}
	return nil
}

// account_set_email sets an account's email address, or removes it if
// it is "". The address must be cleaned, lower case and not used by
// another account (see account_by_email).
account_set_email :: proc(a: ^Accounts, acc: ^Account, email: string) -> bool {
	db_write(a.db, .Account_Set_Email, i64(acc.id), email) or_return
	delete(acc.email)
	acc.email = strings.clone(email)
	return true
}

// account_set_verify sets an account's flags and the code and expiry
// needed to verify its email address (verify.odin).
account_set_verify :: proc(
	a: ^Accounts,
	acc: ^Account,
	flags: proto.Account_Flags,
	code: string,
	expires: i64,
) -> bool {
	db_write(
		a.db,
		.Account_Set_Verify,
		i64(acc.id),
		i64(transmute(u8)flags),
		code,
		expires,
	) or_return
	acc.flags = flags
	delete(acc.verify_code)
	acc.verify_code = strings.clone(code)
	acc.verify_expires = expires
	return true
}

// account_seen records that an account was just seen.
account_seen :: proc(a: ^Accounts, acc: ^Account) {
	acc.last_seen = unix_ms()
	_ = db_write(a.db, .Account_Set_Seen, i64(acc.id), acc.last_seen)
}

// device_of returns the device with this key if it is logged in to an
// account.
device_of :: proc(a: ^Accounts, key: [proto.KEY_SIZE]u8) -> ^Device {
	return a.devices[key] or_else nil
}

// device_link logs a device in to an account, after which its key is
// enough to authenticate. A device that was logged in to another account
// is moved to this one, and a device that is already logged in to this
// account just gets its new name.
@(require_results)
device_link :: proc(
	a: ^Accounts,
	key: [proto.KEY_SIZE]u8,
	acc: ^Account,
	name, agent: string,
) -> ^Device {
	key := key
	now := unix_ms()
	if !db_write(a.db, .Device_Put, key[:], i64(acc.id), name, now, agent) {
		return nil
	}
	d := a.devices[key] or_else nil
	if d == nil {
		d = new(Device)
		d.key = key
		a.devices[key] = d
	}
	delete(d.name)
	delete(d.agent)
	d.name = strings.clone(name)
	d.agent = strings.clone(agent)
	d.account = acc.id
	d.created, d.last_seen = now, now
	return d
}

// device_unlink logs a device out permanently, so it has to log in again.
device_unlink :: proc(a: ^Accounts, key: [proto.KEY_SIZE]u8) -> bool {
	key := key
	d := a.devices[key] or_else nil
	if d == nil {
		return false
	}
	db_write(a.db, .Device_Delete, key[:]) or_return
	delete_key(&a.devices, key)
	delete(d.name)
	delete(d.agent)
	free(d)
	return true
}

// device_seen records that a device just connected.
device_seen :: proc(a: ^Accounts, d: ^Device) {
	key := d.key
	d.last_seen = unix_ms()
	_ = db_write(a.db, .Device_Set_Seen, key[:], d.last_seen)
}

// devices_of returns an account's devices, oldest first, allocated with
// the temp allocator.
devices_of :: proc(a: ^Accounts, acc: ^Account) -> []^Device {
	list := make([dynamic]^Device, context.temp_allocator)
	for _, d in a.devices {
		if d.account == acc.id {
			i := 0
			for i < len(list) &&
			    (list[i].created < d.created ||
					    (list[i].created == d.created && key_less(list[i].key, d.key))) {
				i += 1
			}
			inject_at(&list, i, d)
		}
	}
	return list[:]
}

@(private = "file")
key_less :: proc(a, b: [proto.KEY_SIZE]u8) -> bool {
	for x, i in a {
		if x != b[i] {
			return x < b[i]
		}
	}
	return false
}

// permissions returns what an account may do. The owner may do
// everything, anyone else may do what their roles allow (calculated in
// roles.odin).
permissions :: proc(acc: ^Account) -> proto.Permissions {
	if .Owner in acc.flags {
		return ~proto.Permissions{}
	}
	return acc.perms
}

// can is whether an account has a permission. Anything that requires a
// permission should check it here.
can :: proc(acc: ^Account, permission: proto.Permission) -> bool {
	return acc != nil && permission in permissions(acc)
}

// account_record is an account as it is sent to everyone. Whether it has
// to change its password is only sent to the account itself (see Self).
account_record :: proc(acc: ^Account) -> proto.Account {
	return {
		id = acc.id,
		flags = acc.flags - {.Must_Change, .Unverified},
		username = acc.username,
		display = acc.display,
		status = acc.status,
		status_until = proto.Unix_Ms(acc.status_until),
		avatar = acc.avatar,
		roles = acc.roles[:],
		activity = activity_of(acc),
	}
}
