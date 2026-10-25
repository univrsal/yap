package server

import "core:net"
import "core:os"
import "core:testing"
import "core:time"

import "common:proto"
import "gate"

// Tests of accounts and logging in, with the harness in harness_test.odin.

@(test)
test_first_admin :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)

	// An empty server gets its owner account, but only once.
	testing.expect(t, ensure_first_admin(&a, HASH_PARAMS_TEST))
	testing.expect_value(t, len(a.by_id), 1)
	admin := account_find(&a, FIRST_ADMIN)
	testing.expect(t, admin != nil)
	testing.expect_value(t, admin.flags, proto.Account_Flags{.Owner, .Must_Change})
	testing.expect(t, ensure_first_admin(&a, HASH_PARAMS_TEST))
	testing.expect_value(t, len(a.by_id), 1)

	// The owner may do everything. Anybody else may only do what everyone
	// may, which is attaching files.
	for p in proto.Permission {
		testing.expect(t, can(admin, p))
	}
	p := password_of("password one")
	secret, _ := secret_make(&p, HASH_PARAMS_TEST)
	other := account_add(&a, "other", "Other", secret, {})
	testing.expect(t, other != nil)
	for p in proto.Permission {
		testing.expect_value(t, can(other, p), p == .Attach_Files)
	}
	testing.expect(t, !can(nil, .Manage_Accounts))
	// What others are told about an account leaves out the flags that
	// only concern the account itself.
	testing.expect_value(t, account_record(admin).flags, proto.Account_Flags{.Owner})
}

@(test)
test_supplied_first_admin :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)

	text := "initial admin password"
	testing.expect(t, ensure_first_admin(&a, HASH_PARAMS_TEST, text))
	admin := account_find(&a, FIRST_ADMIN)
	testing.expect(t, admin != nil)
	testing.expect_value(t, admin.flags, proto.Account_Flags{.Owner})
	secret, secret_ok := account_secret(&a, admin)
	testing.expect(t, secret_ok)
	password := password_of(text)
	testing.expect(t, secret_matches(&password, &secret))
}

@(test)
test_generated_password :: proc(t: ^testing.T) {
	a, b: [GENERATED_PASSWORD_SIZE]u8
	one := generated_password(&a)
	two := generated_password(&b)
	testing.expect_value(t, len(one), GENERATED_PASSWORD_SIZE)
	testing.expect(t, one != two)
	testing.expect(t, proto.account_password_ok(one))
	for ch in one {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '2' ..= '9':
		case:
			testing.expectf(t, false, "%q in a generated password", ch)
		}
	}
}

@(test)
test_secrets :: proc(t: ^testing.T) {
	right := password_of("the right one")
	wrong := password_of("the wrong one")
	secret, ok := secret_make(&right, HASH_PARAMS_TEST)
	testing.expect(t, ok)
	testing.expect(t, secret_matches(&right, &secret))
	testing.expect(t, !secret_matches(&wrong, &secret))
	// Hashing the same password again uses another salt and therefore
	// produces another hash.
	again, _ := secret_make(&right, HASH_PARAMS_TEST)
	testing.expect(t, again.salt != secret.salt)
	testing.expect(t, again.hash != secret.hash)
	// An unknown parameter set matches nothing.
	secret.params = 99
	testing.expect(t, !secret_matches(&right, &secret))
	_, ok = secret_make(&right, 99)
	testing.expect(t, !ok)
}

@(test)
test_hash_queue_bound :: proc(t: ^testing.T) {
	// Without a thread taking jobs from the queue, they stay in it.
	w: Hash_Worker
	defer delete(w.jobs)
	job: Hash_Job
	for i in 0 ..< HASH_QUEUE_MOST {
		id, ok := hash_submit(&w, &job)
		testing.expect(t, ok)
		testing.expect_value(t, id, u64(i + 1))
	}
	_, ok := hash_submit(&w, &job)
	testing.expect(t, !ok)
	_, any := hash_poll(&w)
	testing.expect(t, !any)
}

@(test)
test_accounts_kept :: proc(t: ^testing.T) {
	// What was created is still there when the database is opened again.
	dir := test_dir(t)
	defer remove_tree(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	key := [proto.KEY_SIZE]u8 {
		0  = 7,
		31 = 9,
	}
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		a: Accounts
		testing.expect(t, accounts_load(&a, &db))
		defer accounts_destroy(&a)
		p := password_of("kept password")
		secret, _ := secret_make(&p, HASH_PARAMS_TEST)
		acc := account_add(&a, "alice", "Alice A.", secret, {.Must_Change})
		testing.expect(t, acc != nil)
		// A username is taken regardless of its case. account_add is only
		// given cleaned usernames, and the database would reject a
		// duplicate as well.
		testing.expect(t, account_add(&a, "alice", "Another", secret, {}) == nil)
		testing.expect(t, device_link(&a, key, acc, "laptop", "") != nil)
		testing.expect(t, account_set_display(&a, acc, "Alice B."))
		account_seen(&a, acc)
	}
	db: DB
	testing.expect(t, db_open(&db, path))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)
	acc := account_find(&a, "alice")
	testing.expect(t, acc != nil)
	testing.expect_value(t, acc.display, "Alice B.")
	testing.expect_value(t, acc.flags, proto.Account_Flags{.Must_Change})
	testing.expect(t, acc.last_seen > 0)
	d := device_of(&a, key)
	testing.expect(t, d != nil)
	testing.expect_value(t, d.account, acc.id)
	testing.expect_value(t, d.name, "laptop")
	p := password_of("kept password")
	secret, found := account_secret(&a, acc)
	testing.expect(t, found)
	testing.expect(t, secret_matches(&p, &secret))
}

@(test)
test_login :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice := ts_account(t, &ts, "alice", "alice's password")
	ts_account(t, &ts, "bob", "bob's password")

	// A device the server hasn't seen can ask for the server's info (and
	// its picture, see server_info_test.odin), log in and register (see
	// register_test.odin). It can do nothing else.
	u := ts_connect(&ts)
	testing.expect(t, u.account == nil)
	testing.expect(t, u.key in s.waiting && u.key not_in s.conns)
	status, _ := ts_ask(t, &ts, u, .Server_Info)
	testing.expect_value(t, status, proto.Status.Ok)
	for op in proto.Request_Op {
		if op == .Server_Info || op == .Server_Icon || op == .Auth_Login || op == .Register {
			continue
		}
		status, _ = ts_ask(t, &ts, u, op)
		testing.expectf(t, status == .Unauthenticated, "%v answered %v before login", op, status)
	}

	// Every kind of invalid login is rejected.
	flags: proto.Account_Flags
	status, _ = ts_login(t, &ts, u, "alice", "not her password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_login(t, &ts, u, "nobody", "alice's password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_login(t, &ts, u, "not a name!", "alice's password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_login(t, &ts, u, "alice", "")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_ask(t, &ts, u, .Auth_Login, []u8{1, 2})
	testing.expect_value(t, status, proto.Status.Invalid)
	testing.expect(t, u.account == nil)
	testing.expect_value(t, len(ts_events(t, &ts, u)), 0)

	// A correct login works regardless of the case the username was typed in.
	status, flags = ts_login(t, &ts, u, "Alice", "alice's password", "laptop")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags, proto.Account_Flags{})
	testing.expect(t, u.account == alice)
	testing.expect(t, u.key in s.conns && u.key not_in s.waiting)
	testing.expect_value(t, len(alice.conns), 1)
	testing.expect_value(t, alice.failures, 0)

	// The connection is sent the current state: the roles, every
	// account, the channels it's in (the home channel to start with) and
	// finally who it is.
	events := ts_events(t, &ts, u)
	testing.expect_value(t, len(events), 8)
	testing.expect_value(t, events[0].op, proto.Event_Op.Sync_Begin)
	testing.expect_value(t, events[1].op, proto.Event_Op.Role_Changed)
	everyone, role_ok := proto.decode_role(events[1].body)
	testing.expect(t, role_ok && everyone.id == proto.EVERYONE_ROLE && everyone.name == "everyone")
	for e, i in events[2:4] {
		testing.expect_value(t, e.op, proto.Event_Op.Account_Changed)
		acc, ok := proto.decode_account(e.body)
		testing.expect(t, ok)
		testing.expect_value(t, acc.username, "alice" if i == 0 else "bob")
	}
	testing.expect_value(t, events[4].op, proto.Event_Op.Conv_Changed)
	home, home_ok := proto.decode_conv(events[4].body)
	testing.expect(t, home_ok)
	testing.expect_value(t, home.name, "Lobby")
	testing.expect_value(t, home.flags, proto.Conv_Flags{.Home})
	testing.expect(t, home.member)
	// There are no custom emoji.
	testing.expect_value(t, events[5].op, proto.Event_Op.Emoji_Sheet)
	sheet, sheet_ok := proto.decode_emoji_sheet(events[5].body)
	testing.expect(t, sheet_ok && sheet.blob == 0 && len(sheet.names) == 0)
	testing.expect_value(t, events[6].op, proto.Event_Op.Self)
	me, perms, self_flags, ok := proto.decode_self(events[6].body)
	testing.expect(t, ok)
	testing.expect_value(t, me, alice.id)
	testing.expect_value(t, perms, proto.Permissions{.Attach_Files})
	testing.expect_value(t, self_flags, proto.Account_Flags{})
	testing.expect_value(t, events[7].op, proto.Event_Op.Sync_End)

	// A connection that is logged in can't log in again.
	status, _ = ts_login(t, &ts, u, "bob", "bob's password")
	testing.expect_value(t, status, proto.Status.Conflict)

	// The device now belongs to the account, so when it connects again
	// its key is enough to log in.
	key := u.key
	ts_disconnect(&ts, u)
	testing.expect_value(t, len(alice.conns), 0)
	testing.expect(t, alice.last_seen > 0)
	again := ts_connect(&ts, key)
	testing.expect(t, again.account == alice)
	_, synced := has_event(ts_events(t, &ts, again), .Sync_End)
	testing.expect(t, synced)

	// This lasts until the device logs out, which makes it an unknown
	// device again.
	status, _ = ts_ask(t, &ts, again, .Auth_Logout)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, again.account == nil)
	testing.expect(t, again.key in s.waiting)
	testing.expect(t, device_of(&s.accounts, key) == nil)
	ts_disconnect(&ts, again)
	testing.expect(t, ts_connect(&ts, key).account == nil)
}

@(test)
test_login_lock :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	u := ts_connect(&ts)

	for _ in 0 ..< AUTH_FREE_FAILURES {
		status, _ := ts_login(t, &ts, u, "alice", "a guess at it")
		testing.expect_value(t, status, proto.Status.Wrong_Password)
	}
	testing.expect_value(t, alice.failures, AUTH_FREE_FAILURES)
	// That was one attempt too many, so for a while even the correct
	// password is rejected.
	status, _ := ts_login(t, &ts, u, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Rate_Limited)
	testing.expect(t, u.account == nil)

	// Once the wait is over the correct password is accepted again and
	// the count starts again.
	alice.locked_until = time.tick_now()
	status, _ = ts_login(t, &ts, u, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, alice.failures, 0)
}

@(test)
test_account_create :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "alice's password")
	admin := ts_connect(&ts)
	alice := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, alice, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, admin)
	ts_events(t, &ts, alice)

	buf: [proto.ACCOUNT_BODY_MAX]u8
	body: []u8

	// Only accounts that can manage accounts may create them.
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Account_Create,
		proto.encode_account_create(buf[:], "bob", "first password", "Bob"),
	)
	testing.expect_value(t, status, proto.Status.Denied)

	// Invalid usernames or passwords don't create an account.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "b", "first password", "Bob"),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "bob", "short", "Bob"),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "ALICE", "first password", ""),
	)
	testing.expect_value(t, status, proto.Status.Conflict)

	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "Bob", "first password", "  Bob\tB. "),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, ok := proto.decode_account_id(body)
	testing.expect(t, ok)
	bob := account_find(&s.accounts, "bob")
	testing.expect(t, bob != nil && bob.id == id)
	testing.expect_value(t, bob.display, "Bob B.")
	testing.expect_value(t, bob.flags, proto.Account_Flags{.Must_Change})

	// Everyone is told about the new account, except that its password
	// has to be changed, which only concerns the account itself.
	for u in ([]^Conn{admin, alice}) {
		e, heard := has_event(ts_events(t, &ts, u), .Account_Changed)
		testing.expect(t, heard)
		acc, _ := proto.decode_account(e.body)
		testing.expect_value(t, acc.id, id)
		testing.expect_value(t, acc.display, "Bob B.")
		testing.expect_value(t, acc.flags, proto.Account_Flags{})
	}

	// If no display name is given, the username is used.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "carol", "first password", ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, account_find(&s.accounts, "carol").display, "carol")

	// Bob logs in with the password he was given, is told to choose his
	// own password and does so.
	b := ts_connect(&ts)
	flags: proto.Account_Flags
	status, flags = ts_login(t, &ts, b, "bob", "first password")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags, proto.Account_Flags{.Must_Change})
	ts_events(t, &ts, b)

	status, _ = ts_ask(
		t,
		&ts,
		b,
		.Password_Change,
		proto.encode_password_change(buf[:], "not it", "bob's own password", false),
	)
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_ask(
		t,
		&ts,
		b,
		.Password_Change,
		proto.encode_password_change(buf[:], "first password", "short", false),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		b,
		.Password_Change,
		proto.encode_password_change(buf[:], "first password", "bob's own password", false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, bob.flags, proto.Account_Flags{})
	e, told := has_event(ts_events(t, &ts, b), .Self)
	testing.expect(t, told)
	_, _, self_flags, _ := proto.decode_self(e.body)
	testing.expect_value(t, self_flags, proto.Account_Flags{})

	// The old password no longer works.
	ts_disconnect(&ts, b)
	testing.expect(t, device_unlink(&s.accounts, b.key))
	c := ts_connect(&ts)
	status, _ = ts_login(t, &ts, c, "bob", "first password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_login(t, &ts, c, "bob", "bob's own password")
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_device_agent :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "alice", "alice's password")

	// The user agent the client reports is stored on a single line and
	// truncated if too long. A client that reports nothing gets "".
	laptop := ts_connect(&ts)
	phone := ts_connect(&ts)
	buf: [proto.ACCOUNT_BODY_MAX]u8
	long := make([]u8, 200, context.temp_allocator)
	for &b in long {
		b = 'x'
	}
	status, _ := ts_ask(
		t,
		&ts,
		laptop,
		.Auth_Login,
		proto.encode_auth_login(
			buf[:],
			"alice",
			"alice's password",
			"laptop",
			"Firefox 128\non Windows",
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Auth_Login,
		proto.encode_auth_login(buf[:], "alice", "alice's password", "phone", string(long)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, device_of(&ts.s.accounts, laptop.key).agent, "Firefox 128 on Windows")
	testing.expect_value(t, len(device_of(&ts.s.accounts, phone.key).agent), proto.MAX_AGENT)

	body: []u8
	status, body = ts_ask(t, &ts, laptop, .Device_List)
	testing.expect_value(t, status, proto.Status.Ok)
	devices_buf: [8]proto.Device
	devices, ok := proto.decode_devices(body, devices_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 2)
	for d in devices {
		if d.key == laptop.key {
			testing.expect_value(t, d.agent, "Firefox 128 on Windows")
		}
	}

	// It is stored in the database too.
	reloaded: Accounts
	testing.expect(t, accounts_load(&reloaded, &ts.s.db))
	defer accounts_destroy(&reloaded)
	testing.expect_value(t, device_of(&reloaded, laptop.key).agent, "Firefox 128 on Windows")
}

@(test)
test_devices :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "alice's password")
	ts_account(t, &ts, "bob", "bob's password")

	// Two devices of one account connected at the same time.
	laptop := ts_connect(&ts)
	phone := ts_connect(&ts)
	bob := ts_connect(&ts)
	status, _ := ts_login(t, &ts, laptop, "alice", "alice's password", "laptop")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, phone, "alice", "alice's password", "  phone\n")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, bob, "bob", "bob's password", "")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, laptop.account == phone.account)
	testing.expect_value(t, len(laptop.account.conns), 2)
	ts_events(t, &ts, phone)

	body: []u8
	status, body = ts_ask(t, &ts, laptop, .Device_List)
	testing.expect_value(t, status, proto.Status.Ok)
	devices_buf: [8]proto.Device
	devices, ok := proto.decode_devices(body, devices_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 2)
	for d in devices {
		switch d.key {
		case laptop.key:
			testing.expect_value(t, d.name, "laptop")
			testing.expect_value(t, d.flags, proto.Device_Flags{.Current, .Online})
		case phone.key:
			testing.expect_value(t, d.name, "phone")
			testing.expect_value(t, d.flags, proto.Device_Flags{.Online})
		case:
			testing.fail(t)
		}
	}

	// An account can't revoke somebody else's device, and the device
	// appears not to exist.
	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(t, &ts, bob, .Device_Revoke, proto.encode_device_revoke(buf[:], phone.key))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect(t, phone.account != nil)

	// An account can revoke its own device. The device is logged out
	// immediately, is told why and has to log in again.
	status, _ = ts_ask(
		t,
		&ts,
		laptop,
		.Device_Revoke,
		proto.encode_device_revoke(buf[:], phone.key),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, phone.account == nil)
	testing.expect(t, phone.key in s.waiting && phone.key not_in s.conns)
	testing.expect_value(t, len(laptop.account.conns), 1)
	e, told := has_event(ts_events(t, &ts, phone), .Logged_Out)
	testing.expect(t, told)
	testing.expect_value(t, e.body[0], u8(proto.Logout_Reason.Revoked))
	status, _ = ts_ask(t, &ts, phone, .Device_List)
	testing.expect_value(t, status, proto.Status.Unauthenticated)
	phone_key := phone.key
	ts_disconnect(&ts, phone)
	testing.expect(t, ts_connect(&ts, phone_key).account == nil)

	// Changing the password can also log out the other devices.
	tablet := ts_connect(&ts)
	status, _ = ts_login(t, &ts, tablet, "alice", "alice's password", "tablet")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, tablet)
	status, _ = ts_ask(
		t,
		&ts,
		laptop,
		.Password_Change,
		proto.encode_password_change(buf[:], "alice's password", "a new password", true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, laptop.account != nil)
	testing.expect(t, tablet.account == nil)
	e, told = has_event(ts_events(t, &ts, tablet), .Logged_Out)
	testing.expect(t, told)
	testing.expect_value(t, e.body[0], u8(proto.Logout_Reason.Password_Changed))
}

@(test)
test_password_set_by_admin :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	owner := ts_account(t, &ts, "admin", "admin's password", {.Owner})
	alice := ts_account(t, &ts, "alice", "alice's password")
	admin := ts_connect(&ts)
	a := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, a, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, a)

	buf: [proto.ACCOUNT_BODY_MAX]u8
	// Setting a password is denied without permission, and unknown
	// accounts and invalid passwords are rejected.
	status, _ = ts_ask(
		t,
		&ts,
		a,
		.Account_Password_Set,
		proto.encode_account_password_set(buf[:], alice.id, "another password"),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Password_Set,
		proto.encode_account_password_set(buf[:], 999, "another password"),
	)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Password_Set,
		proto.encode_account_password_set(buf[:], alice.id, "short"),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	testing.expect(t, a.account == alice)

	// Alice forgot her password. The admin sets a new one, which logs
	// out her devices and is only valid until she chooses her own.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Password_Set,
		proto.encode_account_password_set(buf[:], alice.id, "another password"),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, a.account == nil)
	testing.expect(t, admin.account == owner)
	testing.expect_value(t, alice.flags, proto.Account_Flags{.Must_Change})
	e, told := has_event(ts_events(t, &ts, a), .Logged_Out)
	testing.expect(t, told)
	testing.expect_value(t, e.body[0], u8(proto.Logout_Reason.Password_Changed))

	flags: proto.Account_Flags
	status, _ = ts_login(t, &ts, a, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, flags = ts_login(t, &ts, a, "alice", "another password")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags, proto.Account_Flags{.Must_Change})
}

@(test)
test_profile_set :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice := ts_account(t, &ts, "alice", "alice's password")
	ts_account(t, &ts, "bob", "bob's password")
	a := ts_connect(&ts)
	b := ts_connect(&ts)
	status, _ := ts_login(t, &ts, a, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, b, "bob", "bob's password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, a)
	ts_events(t, &ts, b)

	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(
		t,
		&ts,
		a,
		.Profile_Set,
		proto.encode_profile_set(
			buf[:],
			{mask = proto.PROFILE_DISPLAY, display = "  Alice\x00 the Great "},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, alice.display, "Alice the Great")
	e, heard := has_event(ts_events(t, &ts, b), .Account_Changed)
	testing.expect(t, heard)
	acc, _ := proto.decode_account(e.body)
	testing.expect_value(t, acc.display, "Alice the Great")
	testing.expect_value(t, conn_name(a), "Alice the Great")

	// An empty name is invalid, and setting the same name again doesn't
	// notify anyone.
	status, _ = ts_ask(
		t,
		&ts,
		a,
		.Profile_Set,
		proto.encode_profile_set(buf[:], {mask = proto.PROFILE_DISPLAY, display = " \t "}),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		a,
		.Profile_Set,
		proto.encode_profile_set(
			buf[:],
			{mask = proto.PROFILE_DISPLAY, display = "Alice the Great"},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(ts_events(t, &ts, b)), 0)
	testing.expect_value(t, alice.display, "Alice the Great")
}

@(test)
test_login_gone_before_answer :: proc(t: ^testing.T) {
	// The requester has disconnected by the time the password is hashed,
	// so nothing happens on their behalf.
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice := ts_account(t, &ts, "alice", "alice's password")
	u := ts_connect(&ts)
	buf: [proto.ACCOUNT_BODY_MAX]u8
	rpc_handle(
		s,
		u,
		proto.encode_request(
			1,
			.Auth_Login,
			proto.encode_auth_login(buf[:], "alice", "alice's password", "x"),
		),
	)
	testing.expect(t, u.auth_busy)
	// A second request while the first is in progress is rate limited.
	rpc_handle(
		s,
		u,
		proto.encode_request(
			2,
			.Auth_Login,
			proto.encode_auth_login(buf[:], "alice", "alice's password", "x"),
		),
	)
	ts_pump(t, &ts, u)
	testing.expect_value(t, ts.clients[u].responses[2].status, proto.Status.Rate_Limited)

	delete_key(&s.waiting, u.key)
	for len(s.auth.pending) > 0 {
		auth_sync(s)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, u.account == nil)
	testing.expect_value(t, len(alice.conns), 0)
	testing.expect(t, device_of(&s.accounts, u.key) == nil)

}

@(test)
test_login_in_flight :: proc(t: ^testing.T) {
	// Guesses that are still being hashed count towards the free ones, so
	// sending many at once from different connections doesn't get around
	// the lock.
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice := ts_account(t, &ts, "alice", "alice's password")
	conns: [AUTH_FREE_FAILURES + 1]^Conn
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body := proto.encode_auth_login(buf[:], "alice", "a guess at it", "x")
	for &u, i in conns {
		u = ts_connect(&ts)
		rpc_handle(s, u, proto.encode_request(1, .Auth_Login, body))
		ts_pump(t, &ts, u)
		if i < AUTH_FREE_FAILURES {
			testing.expect(t, u.auth_busy)
		}
	}
	testing.expect_value(t, alice.checking, AUTH_FREE_FAILURES)
	last := ts.clients[conns[AUTH_FREE_FAILURES]]
	testing.expect_value(t, last.responses[1].status, proto.Status.Rate_Limited)

	for len(s.auth.pending) > 0 {
		auth_sync(s)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, alice.checking, 0)
	testing.expect_value(t, alice.failures, AUTH_FREE_FAILURES)
}

@(test)
test_addr_buckets :: proc(t: ^testing.T) {
	b := gate.Addr_Buckets {
		burst = 3,
		every = time.Hour,
	}
	defer gate.addr_buckets_destroy(&b)
	one := net.Endpoint{net.IP4_Address{192, 0, 2, 1}, 1000}
	same := net.Endpoint{net.IP4_Address{192, 0, 2, 1}, 2000} // only the port differs
	other := net.Endpoint{net.IP4_Address{192, 0, 2, 2}, 1000}
	for _ in 0 ..< 3 {
		testing.expect(t, gate.addr_take(&b, one))
	}
	testing.expect(t, !gate.addr_take(&b, same))
	testing.expect(t, !gate.addr_allowed(&b, one))
	testing.expect(t, gate.addr_take(&b, other))

	// Counting what has already happened goes into debt, which takes longer
	// to pay off.
	gate.addr_spend(&b, other)
	gate.addr_spend(&b, other)
	gate.addr_spend(&b, other)
	testing.expect(t, !gate.addr_allowed(&b, other))
	bucket := b.buckets.by_key[gate.key_of(other)]
	testing.expect(t, bucket.tokens < 0)

	// Tokens come back with time.
	bucket = b.buckets.by_key[gate.key_of(one)]
	bucket.last = time.tick_add(bucket.last, -2 * time.Hour)
	b.buckets.by_key[gate.key_of(one)] = bucket
	testing.expect(t, gate.addr_allowed(&b, one))
	testing.expect(t, gate.addr_take(&b, one))
	testing.expect(t, gate.addr_take(&b, one))
	testing.expect(t, !gate.addr_take(&b, one))
}
