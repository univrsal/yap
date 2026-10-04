package server

import "core:os"
import "core:testing"
import "core:time"

import "common:proto"

/*
Tests of accounts and logging in. They run a Server without its socket:
connections are made by hand, requests are given to rpc_handle as they
would come off a connection's stream, and what the server queues on that
stream in return is read off it the way a client would. The other
tests of the server use the same (the ts_ procedures).

Passwords are hashed by the real thread, with the parameter set that
makes it quick.
*/

// A connection's other end: the stream a client would have, and what
// has come out of it.
Test_Client :: struct {
	stream:    proto.Stream,
	responses: map[u32]Test_Response,
	events:    [dynamic]Test_Event,
}

Test_Response :: struct {
	status: proto.Status,
	body:   []u8, // temp allocator
}

Test_Event :: struct {
	op:   proto.Event_Op,
	body: []u8, // temp allocator
}

Test_Server :: struct {
	s:        Server,
	clients:  map[^Conn]^Test_Client,
	requests: u32,
	keys:     u8,
}

TEST_CHANNELS := []string{"Lobby", "Gaming"}

ts_open :: proc(t: ^testing.T, ts: ^Test_Server, db_path := DB_MEMORY) {
	s := &ts.s
	s.version = 1
	s.auth.params = HASH_PARAMS_TEST
	testing.expect(t, db_open(&s.db, db_path))
	testing.expect(t, accounts_load(&s.accounts, &s.db))
	testing.expect(t, convs_load(&s.convs, &s.db, TEST_CHANNELS, &s.accounts))
	testing.expect(t, hash_worker_start(&s.hasher))
}

ts_close :: proc(ts: ^Test_Server) {
	s := &ts.s
	hash_worker_stop(&s.hasher)
	auth_destroy(&s.auth)
	for u, client in ts.clients {
		proto.stream_destroy(&client.stream)
		delete(client.responses)
		delete(client.events)
		free(client)
		proto.stream_destroy(&u.stream)
		drop_conn_transfers(u)
		free(u)
	}
	delete(ts.clients)
	delete(s.conns)
	delete(s.waiting)
	convs_destroy(&s.convs)
	retention_close(&s.retention)
	blob_store_close(&s.blobs)
	files_destroy(s)
	accounts_destroy(&s.accounts)
	db_close(&s.db)
}

// ts_account makes an account straight in the store, with a password
// known to the test.
ts_account :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	username, password: string,
	flags: proto.Account_Flags = {},
) -> ^Account {
	p := password_of(password)
	secret, ok := secret_make(&p, HASH_PARAMS_TEST)
	testing.expect(t, ok)
	acc := account_add(&ts.s.accounts, username, username, secret, flags)
	testing.expect(t, acc != nil)
	testing.expect(t, conv_member_add(&ts.s.convs, ts.s.convs.home, acc.id))
	return acc
}

// ts_connect is a device connecting: a new connection under `key`, or
// under a key no other has. Like the real thing, a device the server
// knows is logged in at once.
ts_connect :: proc(ts: ^Test_Server, key: [proto.KEY_SIZE]u8 = {}) -> ^Conn {
	s := &ts.s
	u := new(Conn)
	u.key = key
	if key == {} {
		ts.keys += 1
		u.key[0] = ts.keys
	}
	s.last_num += 1
	u.num = s.last_num
	u.instance = u64(u.num)
	stream_init(&u.stream)
	s.waiting[u.key] = u
	ts.clients[u] = new(Test_Client)
	auth_known_device(s, u)
	return u
}

// ts_disconnect is a connection going away, as when its last session
// does.
ts_disconnect :: proc(ts: ^Test_Server, u: ^Conn) {
	conn_logout(&ts.s, u)
	delete_key(&ts.s.waiting, u.key)
}

// ts_pump moves what the server has queued for a connection to its
// client end, and sorts what arrives into responses and events.
ts_pump :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) {
	client := ts.clients[u]
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	now := time.tick_now()
	for {
		frame, ok := proto.stream_next_frame(&u.stream, now, proto.STREAM_RESEND, buf[:])
		if !ok {
			break
		}
		testing.expect_value(
			t,
			proto.stream_receive(&client.stream, frame),
			proto.Stream_Error.None,
		)
		ack_buf: [proto.STREAM_ACK_SIZE]u8
		if ack, due := proto.stream_ack(&client.stream, &ack_buf); due {
			proto.stream_acked(&u.stream, ack)
		}
	}
	for {
		msg, ok := proto.stream_next(&client.stream)
		if !ok {
			break
		}
		kind, known := proto.app_kind(msg)
		testing.expect(t, known)
		#partial switch kind {
		case .Response:
			id, status, body := proto.decode_response(msg)
			client.responses[id] = {status, temp_copy(body)}
		case .Event:
			op, body := proto.decode_event(msg)
			append(&client.events, Test_Event{op, temp_copy(body)})
		case:
			testing.fail(t)
		}
	}
}

temp_copy :: proc(data: []u8) -> []u8 {
	out := make([]u8, len(data), context.temp_allocator)
	copy(out, data)
	return out
}

// ts_ask makes a request as `u` and waits for its answer, which for
// anything with a password in it comes from the hashing thread.
ts_ask :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	op: proto.Request_Op,
	body: []u8 = nil,
) -> (
	status: proto.Status,
	response: []u8,
) {
	ts.requests += 1
	id := ts.requests
	rpc_handle(&ts.s, u, proto.encode_request(id, op, body))
	client := ts.clients[u]
	for _ in 0 ..< 5000 {
		auth_sync(&ts.s)
		ts_pump(t, ts, u)
		if r, answered := client.responses[id]; answered {
			return r.status, r.body
		}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "no answer to a request")
}

ts_login :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	username, password: string,
	device := "test device",
) -> (
	status: proto.Status,
	flags: proto.Account_Flags,
) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		ts,
		u,
		.Auth_Login,
		proto.encode_auth_login(buf[:], username, password, device),
	)
	if status == .Ok {
		ok: bool
		_, flags, ok = proto.decode_auth_login_response(body)
		testing.expect(t, ok)
	}
	return
}

// ts_events takes the events a connection has been sent since the last
// time.
ts_events :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> []Test_Event {
	ts_pump(t, ts, u)
	client := ts.clients[u]
	out := make([]Test_Event, len(client.events), context.temp_allocator)
	copy(out, client.events[:])
	clear(&client.events)
	return out
}

has_event :: proc(events: []Test_Event, op: proto.Event_Op) -> (Test_Event, bool) {
	for e in events {
		if e.op == op {
			return e, true
		}
	}
	return {}, false
}

@(test)
test_first_admin :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)

	// An empty server gets its owner, once.
	testing.expect(t, ensure_first_admin(&a, HASH_PARAMS_TEST))
	testing.expect_value(t, len(a.by_id), 1)
	admin := account_find(&a, FIRST_ADMIN)
	testing.expect(t, admin != nil)
	testing.expect_value(t, admin.flags, proto.Account_Flags{.Owner, .Must_Change})
	testing.expect(t, ensure_first_admin(&a, HASH_PARAMS_TEST))
	testing.expect_value(t, len(a.by_id), 1)

	// The owner may do everything, and anybody else only what everyone
	// may: attach files.
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
	// What others are told of an account leaves out what's its own.
	testing.expect_value(t, account_record(admin).flags, proto.Account_Flags{.Owner})
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
	// The same password again gets another salt, and so another hash.
	again, _ := secret_make(&right, HASH_PARAMS_TEST)
	testing.expect(t, again.salt != secret.salt)
	testing.expect(t, again.hash != secret.hash)
	// A parameter set that isn't known matches nothing.
	secret.params = 99
	testing.expect(t, !secret_matches(&right, &secret))
	_, ok = secret_make(&right, 99)
	testing.expect(t, !ok)
}

@(test)
test_hash_queue_bound :: proc(t: ^testing.T) {
	// With no thread taking them, jobs stay where they are.
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
	// What's made is there when the database is opened again.
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
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
		// A username is taken whatever its case; account_add is given
		// clean ones, and the database would refuse the other as well.
		testing.expect(t, account_add(&a, "alice", "Another", secret, {}) == nil)
		testing.expect(t, device_link(&a, key, acc, "laptop") != nil)
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
test_schema_upgrade :: proc(t: ^testing.T) {
	// A database from before accounts is brought up to date, with what
	// it had left alone.
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(t, db_meta_set(&db, "kept", 5))
		db_commit(&db)
		testing.expect(
			t,
			db_exec(
				&db,
				"DROP TABLE files_fts; DROP TABLE attachments; DROP TABLE messages_fts; DROP TABLE account_roles; DROP TABLE roles; DROP TABLE settings; DROP TABLE reactions; DROP TABLE mentions; DROP TABLE pins; DROP TABLE buddies; DROP TABLE messages; DROP TABLE members; DROP TABLE convs; DROP TABLE devices; DROP TABLE accounts; PRAGMA user_version = 1",
			),
		)
		db_close(&db)
	}
	db: DB
	testing.expect(t, db_open(&db, path))
	defer db_close(&db)
	version, _ := db_pragma_int(&db, "PRAGMA user_version")
	testing.expect_value(t, version, SCHEMA_VERSION)
	kept, found := db_meta(&db, "kept")
	testing.expect(t, found)
	testing.expect_value(t, kept, 5)
	a: Accounts
	testing.expect(t, accounts_load(&a, &db))
	defer accounts_destroy(&a)
	testing.expect_value(t, len(a.by_id), 0)
}

@(test)
test_login :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice := ts_account(t, &ts, "alice", "alice's password")
	ts_account(t, &ts, "bob", "bob's password")

	// A device the server hasn't seen can ask what it's talking to and
	// log in, and that's all.
	u := ts_connect(&ts)
	testing.expect(t, u.account == nil)
	testing.expect(t, u.key in s.waiting && u.key not_in s.conns)
	status, _ := ts_ask(t, &ts, u, .Server_Info)
	testing.expect_value(t, status, proto.Status.Ok)
	for op in proto.Request_Op {
		if op == .Server_Info || op == .Auth_Login {
			continue
		}
		status, _ = ts_ask(t, &ts, u, op)
		testing.expectf(t, status == .Unauthenticated, "%v answered %v before login", op, status)
	}

	// Wrong in every way it can be.
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

	// And right, in whatever case the username was typed.
	status, flags = ts_login(t, &ts, u, "Alice", "alice's password", "laptop")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, flags, proto.Account_Flags{})
	testing.expect(t, u.account == alice)
	testing.expect(t, u.key in s.conns && u.key not_in s.waiting)
	testing.expect_value(t, len(alice.conns), 1)
	testing.expect_value(t, alice.failures, 0)

	// It's told how things are: the roles, every account, the channels
	// it's in (the home channel, for a start), then who it is.
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
	// No emoji of its own.
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

	// Logged in, there's no logging in again.
	status, _ = ts_login(t, &ts, u, "bob", "bob's password")
	testing.expect_value(t, status, proto.Status.Conflict)

	// The device is the account's now: when it connects again, its key
	// is enough.
	key := u.key
	ts_disconnect(&ts, u)
	testing.expect_value(t, len(alice.conns), 0)
	testing.expect(t, alice.last_seen > 0)
	again := ts_connect(&ts, key)
	testing.expect(t, again.account == alice)
	_, synced := has_event(ts_events(t, &ts, again), .Sync_End)
	testing.expect(t, synced)

	// Until it logs out, which makes it a stranger again.
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
	// That was one too many: for a while not even the right one is taken.
	status, _ := ts_login(t, &ts, u, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Rate_Limited)
	testing.expect(t, u.account == nil)

	// Once the wait is over it is, and the count starts again.
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

	// Only who manages accounts makes them.
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Account_Create,
		proto.encode_account_create(buf[:], "bob", "first password", "Bob"),
	)
	testing.expect_value(t, status, proto.Status.Denied)

	// Nothing that couldn't be an account is made into one.
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

	// Everyone hears of the new account; that its password has to be
	// changed is nobody's business but its own.
	for u in ([]^Conn{admin, alice}) {
		e, heard := has_event(ts_events(t, &ts, u), .Account_Changed)
		testing.expect(t, heard)
		acc, _ := proto.decode_account(e.body)
		testing.expect_value(t, acc.id, id)
		testing.expect_value(t, acc.display, "Bob B.")
		testing.expect_value(t, acc.flags, proto.Account_Flags{})
	}

	// With no name given, it's called by its username.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(buf[:], "carol", "first password", ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, account_find(&s.accounts, "carol").display, "carol")

	// Bob logs in with the password he was given, is told to choose
	// his own, and does.
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

	// The old one is no good any more.
	ts_disconnect(&ts, b)
	testing.expect(t, device_unlink(&s.accounts, b.key))
	c := ts_connect(&ts)
	status, _ = ts_login(t, &ts, c, "bob", "first password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	status, _ = ts_login(t, &ts, c, "bob", "bob's own password")
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_devices :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "alice's password")
	ts_account(t, &ts, "bob", "bob's password")

	// Two devices of one account, connected at once.
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

	// Somebody else's device isn't one's to revoke, and looks as if it
	// weren't there.
	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(t, &ts, bob, .Device_Revoke, proto.encode_device_revoke(buf[:], phone.key))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect(t, phone.account != nil)

	// One's own is: it's logged out there and then, told why, and has
	// to log in again.
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

	// Changing the password can take the other devices with it.
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
	// Not for anyone to do, nor to the owner, nor to nobody.
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

	// Alice forgot hers: the admin sets one, which logs her devices out
	// and is only good until she has chosen her own.
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

	// A name of nothing isn't one, and the same name again is no news.
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
	// Whoever asked has gone by the time the password is hashed: nothing
	// happens on their behalf.
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
	// A second while the first is under way has to wait its turn.
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
