package server

import "core:log"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

/*
Accounts and the devices logged in to them (src/common/proto/accounts.odin):
what the database keeps of them, and the copy the server works from.

There are few of them and nearly everything asks about them (whose
connection is this, what is that account called), so they're all read
into memory when the server starts, and every change is made in both
places. The password's hash is the exception: it stays in the database
and is fetched when somebody logs in.

Nothing here decides who may do what, or takes a while: this is only
where accounts and devices are kept. Logging in and the rest of what
clients ask for is in auth.odin.
*/

Account :: struct {
	id:           proto.Account_Id,
	username:     string, // owned; lower case
	display:      string, // owned
	flags:        proto.Account_Flags,
	// Its status (owned; "" for none) and when it ends (0: it doesn't),
	// and its picture (profiles.odin).
	status:       string,
	status_until: i64,
	avatar:       proto.Blob_Id,
	// What it chose to be (online, away, busy or offline), and how
	// everyone was last told it is (activity.odin).
	chosen:       proto.Activity,
	shown:        proto.Activity,
	created:      i64, // Unix milliseconds
	last_seen:    i64, // when its last connection left; 0 if never here
	// Its connections right now, one per device that's here.
	conns:        [dynamic]^Conn,
	// The accounts it keeps in its buddy list (buddies.odin).
	buddies:      [dynamic]proto.Account_Id,
	// Its roles besides everyone's, and what they let it do, worked out
	// again whenever a role or the list changes (roles.odin).
	roles:        [dynamic]proto.Role_Id,
	perms:        proto.Permissions,
	// Wrong passwords in a row, and until when no more are taken
	// (auth.odin).
	failures:     int,
	locked_until: time.Tick,
}

Device :: struct {
	key:       [proto.KEY_SIZE]u8,
	account:   proto.Account_Id,
	name:      string, // owned
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

// accounts_load reads every account and device from the database.
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
		acc.shown = .Offline // nobody is here yet
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
			log.warn("a device in the database has a key of the wrong size; skipping it")
			free(d)
			continue
		}
		d.account = proto.Account_Id(db_col_int(q, 1))
		d.name = db_col_text(q, 2, context.allocator)
		d.created = db_col_int(q, 3)
		d.last_seen = db_col_int(q, 4)
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
		delete(acc.conns)
		delete(acc.buddies)
		delete(acc.roles)
		free(acc)
	}
	for _, d in a.devices {
		delete(d.name)
		free(d)
	}
	delete(a.by_id)
	delete(a.by_name)
	delete(a.devices)
	roles_destroy(a)
	a^ = {}
}

// account_find is the account with this username (as username_clean
// leaves one), or nil.
account_find :: proc(a: ^Accounts, username: string) -> ^Account {
	return a.by_name[username] or_else nil
}

account_by_id :: proc(a: ^Accounts, id: proto.Account_Id) -> ^Account {
	return a.by_id[id] or_else nil
}

/*
account_add makes an account. The username has to be a clean one
(proto.username_clean) that isn't taken, and the display name sanitized
and not empty; nil if the database won't have it.
*/
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
	q := db_stmt(a.db, .Account_Add)
	db_bind_text(q, 1, username)
	db_bind_text(q, 2, display)
	db_bind_blob(q, 3, secret.hash[:])
	db_bind_blob(q, 4, secret.salt[:])
	db_bind_int(q, 5, i64(secret.params))
	db_bind_int(q, 6, i64(transmute(u8)flags))
	db_bind_int(q, 7, now)
	if !db_run(a.db, q) {
		return nil
	}
	acc := new(Account)
	acc.id = proto.Account_Id(db_last_id(a.db))
	acc.username = strings.clone(username)
	acc.display = strings.clone(display)
	acc.flags = flags
	acc.created = now
	acc.shown = .Offline // not here yet (activity.odin)
	a.by_id[acc.id] = acc
	a.by_name[acc.username] = acc
	account_perms_update(a, acc)
	return acc
}

// account_secret fetches an account's password as it's stored.
@(require_results)
account_secret :: proc(a: ^Accounts, acc: ^Account) -> (s: Secret, ok: bool) {
	q := db_stmt(a.db, .Account_Secret)
	db_bind_int(q, 1, i64(acc.id))
	row, stepped := db_step(a.db, q)
	if !stepped || !row {
		return
	}
	defer sqlite.reset(q)
	if !db_col_into(q, 0, s.hash[:]) || !db_col_into(q, 1, s.salt[:]) {
		log.errorf("the password of %s in the database isn't one", acc.username)
		return {}, false
	}
	s.params = int(db_col_int(q, 2))
	return s, true
}

// account_set_password replaces an account's password. `must_change`
// says an admin chose it, and its owner has to choose another.
account_set_password :: proc(a: ^Accounts, acc: ^Account, secret: Secret, must_change: bool) -> bool {
	secret := secret
	q := db_stmt(a.db, .Account_Set_Password)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_blob(q, 2, secret.hash[:])
	db_bind_blob(q, 3, secret.salt[:])
	db_bind_int(q, 4, i64(secret.params))
	db_run(a.db, q) or_return
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
	q := db_stmt(a.db, .Account_Set_Flags)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_int(q, 2, i64(transmute(u8)flags))
	db_run(a.db, q) or_return
	acc.flags = flags
	return true
}

// account_set_display changes what an account is called; `display` is
// sanitized and not empty.
account_set_display :: proc(a: ^Accounts, acc: ^Account, display: string) -> bool {
	q := db_stmt(a.db, .Account_Set_Display)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_text(q, 2, display)
	db_run(a.db, q) or_return
	delete(acc.display)
	acc.display = strings.clone(display)
	return true
}

// account_seen notes that an account was here just now.
account_seen :: proc(a: ^Accounts, acc: ^Account) {
	acc.last_seen = unix_ms()
	q := db_stmt(a.db, .Account_Set_Seen)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_int(q, 2, acc.last_seen)
	_ = db_run(a.db, q)
}

// device_of is the device with this key, if it's logged in to an
// account.
device_of :: proc(a: ^Accounts, key: [proto.KEY_SIZE]u8) -> ^Device {
	return a.devices[key] or_else nil
}

/*
device_link logs a device in to an account: from now on its key is
enough. A device that was logged in to another account is taken from
that one; one already in this account just gets its new name.
*/
@(require_results)
device_link :: proc(a: ^Accounts, key: [proto.KEY_SIZE]u8, acc: ^Account, name: string) -> ^Device {
	key := key
	now := unix_ms()
	q := db_stmt(a.db, .Device_Put)
	db_bind_blob(q, 1, key[:])
	db_bind_int(q, 2, i64(acc.id))
	db_bind_text(q, 3, name)
	db_bind_int(q, 4, now)
	if !db_run(a.db, q) {
		return nil
	}
	d := a.devices[key] or_else nil
	if d == nil {
		d = new(Device)
		d.key = key
		a.devices[key] = d
	}
	delete(d.name)
	d.name = strings.clone(name)
	d.account = acc.id
	d.created, d.last_seen = now, now
	return d
}

// device_unlink logs a device out for good: it has to log in again.
device_unlink :: proc(a: ^Accounts, key: [proto.KEY_SIZE]u8) -> bool {
	key := key
	d := a.devices[key] or_else nil
	if d == nil {
		return false
	}
	q := db_stmt(a.db, .Device_Delete)
	db_bind_blob(q, 1, key[:])
	db_run(a.db, q) or_return
	delete_key(&a.devices, key)
	delete(d.name)
	free(d)
	return true
}

// device_seen notes that a device connected just now.
device_seen :: proc(a: ^Accounts, d: ^Device) {
	key := d.key
	d.last_seen = unix_ms()
	q := db_stmt(a.db, .Device_Set_Seen)
	db_bind_blob(q, 1, key[:])
	db_bind_int(q, 2, d.last_seen)
	_ = db_run(a.db, q)
}

// devices_of is an account's devices, oldest first, in the temp
// allocator.
devices_of :: proc(a: ^Accounts, acc: ^Account) -> []^Device {
	list := make([dynamic]^Device, context.temp_allocator)
	for _, d in a.devices {
		if d.account == acc.id {
			i := 0
			for i < len(list) && (list[i].created < d.created || (list[i].created == d.created && key_less(list[i].key, d.key))) {
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

/*
permissions is what an account may do: the owner everything, anyone
else what its roles allow (worked out by roles.odin).
*/
permissions :: proc(acc: ^Account) -> proto.Permissions {
	if .Owner in acc.flags {
		return ~proto.Permissions{}
	}
	return acc.perms
}

// can is whether an account may do something that takes a permission.
// Everything that does asks here.
can :: proc(acc: ^Account, permission: proto.Permission) -> bool {
	return acc != nil && permission in permissions(acc)
}

// account_record is an account as everyone is told about it. Whether it
// has to change its password is its own business (see Self).
account_record :: proc(acc: ^Account) -> proto.Account {
	return {
		id = acc.id,
		flags = acc.flags - {.Must_Change},
		username = acc.username,
		display = acc.display,
		status = acc.status,
		status_until = proto.Unix_Ms(acc.status_until),
		avatar = acc.avatar,
		roles = acc.roles[:],
		activity = activity_of(acc),
	}
}
