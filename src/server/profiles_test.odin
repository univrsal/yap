package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of statuses, pictures and settings, on the Test_Server of
// auth_test.odin.

@(private = "file")
profile :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, p: proto.Profile_Set) -> proto.Status {
	buf: [proto.ACCOUNT_BODY_MAX + proto.MAX_STATUS_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Profile_Set, proto.encode_profile_set(buf[:], p))
	return status
}

// told is the last Account_Changed a connection was sent about `id`
// since the last look.
@(private = "file")
told :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Account_Id,
) -> (
	a: proto.Account,
	heard: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op != .Account_Changed {
			continue
		}
		got, ok := proto.decode_account(e.body)
		testing.expect(t, ok)
		if got.id == id {
			a, heard = got, true
		}
	}
	return
}

@(test)
test_status :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	now := unix_ms()
	alice_id: proto.Account_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		alice := ts_account(t, &ts, "alice", "a password")
		alice_id = alice.id
		ts_account(t, &ts, "bob", "a password")
		a := logged_in(t, &ts, "alice")
		b := logged_in(t, &ts, "bob")

		// Sanitized, cut to its size, and told to everyone.
		long := "  in a meeting\tuntil three, then lunch, then probably another meeting after that one  "
		testing.expect_value(
			t,
			profile(
				t,
				&ts,
				a,
				{
					mask = proto.PROFILE_STATUS,
					status = long,
					status_until = proto.Unix_Ms(now + 30 * 60 * 1000),
				},
			),
			proto.Status.Ok,
		)
		acc, heard := told(t, &ts, b, alice.id)
		testing.expect(t, heard)
		testing.expect(t, len(acc.status) <= proto.MAX_STATUS_SIZE)
		testing.expect_value(t, acc.status[:13], "in a meeting ")
		testing.expect_value(t, acc.status_until, proto.Unix_Ms(now + 30 * 60 * 1000))
		// The name stays as it was.
		testing.expect_value(t, acc.display, "alice")

		// Not before its time.
		statuses_expire(&ts.s, now + 29 * 60 * 1000)
		_, heard = told(t, &ts, b, alice.id)
		testing.expect(t, !heard)
		testing.expect(t, alice.status != "")

		// One that doesn't end, for bob; and alice's again, ending sooner.
		bob := account_find(&ts.s.accounts, "bob")
		testing.expect_value(
			t,
			profile(t, &ts, b, {mask = proto.PROFILE_STATUS, status = "here", status_until = 0}),
			proto.Status.Ok,
		)
		testing.expect_value(
			t,
			profile(
				t,
				&ts,
				a,
				{
					mask = proto.PROFILE_STATUS,
					status = "brb",
					status_until = proto.Unix_Ms(now + 1000),
				},
			),
			proto.Status.Ok,
		)
		testing.expect_value(t, bob.status, "here")
		ts_events(t, &ts, b)
	}

	// Its time passes while the server is down: cleared once it's up.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	alice := account_by_id(&ts.s.accounts, alice_id)
	testing.expect_value(t, alice.status, "brb")
	// The devices from before, logged in by their keys.
	a := ts_connect(&ts)
	b := ts_connect(&ts)
	testing.expect(t, a.account != nil && a.account.username == "alice")
	testing.expect(t, b.account != nil && b.account.username == "bob")
	ts_events(t, &ts, b)
	statuses_expire(&ts.s, now + 2000)
	acc, heard := told(t, &ts, b, alice_id)
	testing.expect(t, heard)
	testing.expect_value(t, acc.status, "")
	testing.expect_value(t, acc.status_until, 0)
	testing.expect_value(t, alice.status, "")
	testing.expect_value(t, account_find(&ts.s.accounts, "bob").status, "here")

	// No status, no end.
	testing.expect_value(
		t,
		profile(t, &ts, a, {mask = proto.PROFILE_STATUS, status = " ", status_until = 5}),
		proto.Status.Ok,
	)
	testing.expect_value(t, alice.status_until, 0)
}

@(test)
test_avatar :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	alice := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	a := logged_in(t, &ts, "alice")
	b := logged_in(t, &ts, "bob")

	jpeg := test_jpeg(64, 64, 9)
	put := proto.Blob_Put {
		kind   = .Avatar,
		size   = len(jpeg),
		hash   = blob_hash(jpeg),
		width  = 64,
		height = 64,
	}
	blob, stored := upload(t, &ts, a, jpeg, put)
	testing.expect(t, stored)

	// Nobody may fetch it until it's somebody's picture; then anyone may.
	id_buf: [proto.BLOB_GET_SIZE]u8
	status, _ := ts_ask(t, &ts, b, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect_value(
		t,
		profile(t, &ts, a, {mask = proto.PROFILE_AVATAR, avatar = blob}),
		proto.Status.Ok,
	)
	acc, heard := told(t, &ts, b, alice.id)
	testing.expect(t, heard)
	testing.expect_value(t, acc.avatar, blob)
	status, _ = ts_ask(t, &ts, b, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Ok)

	// Too big to announce, not there, or not a picture.
	big := put
	big.width, big.height = 512, 512
	put_buf: [proto.BLOB_PUT_SIZE]u8
	status, _ = ts_ask(t, &ts, a, .Blob_Put, proto.encode_blob_put(&put_buf, big))
	testing.expect_value(t, status, proto.Status.Too_Large)
	big = put
	big.size = proto.MAX_AVATAR_SIZE + 1
	status, _ = ts_ask(t, &ts, a, .Blob_Put, proto.encode_blob_put(&put_buf, big))
	testing.expect_value(t, status, proto.Status.Too_Large)
	testing.expect_value(
		t,
		profile(t, &ts, a, {mask = proto.PROFILE_AVATAR, avatar = 999}),
		proto.Status.Not_Found,
	)
	if sheet, ok := blob_put(&s.blobs, .Emoji_Sheet, test_jpeg(16, 16, 1), 16, 16); ok {
		testing.expect_value(
			t,
			profile(t, &ts, a, {mask = proto.PROFILE_AVATAR, avatar = sheet}),
			proto.Status.Invalid,
		)
	}
	// A message's picture that's too big for a profile.
	photo := test_jpeg(300, 200, 4)
	pic, _ := upload(
		t,
		&ts,
		a,
		photo,
		{kind = .Image, size = len(photo), hash = blob_hash(photo), width = 300, height = 200},
	)
	testing.expect_value(
		t,
		profile(t, &ts, a, {mask = proto.PROFILE_AVATAR, avatar = pic}),
		proto.Status.Too_Large,
	)
	// A refused request changes nothing, not even what came with it.
	testing.expect_value(
		t,
		profile(
			t,
			&ts,
			a,
			{mask = proto.PROFILE_STATUS | proto.PROFILE_AVATAR, status = "x", avatar = 999},
		),
		proto.Status.Not_Found,
	)
	testing.expect_value(t, alice.status, "")
	testing.expect_value(t, alice.avatar, blob)

	// Taken away.
	ts_events(t, &ts, b)
	testing.expect_value(
		t,
		profile(t, &ts, a, {mask = proto.PROFILE_AVATAR, avatar = 0}),
		proto.Status.Ok,
	)
	acc, _ = told(t, &ts, b, alice.id)
	testing.expect_value(t, acc.avatar, 0)
	status, _ = ts_ask(t, &ts, b, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Not_Found)
}

@(private = "file")
setting :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	key: string,
	value: []u8,
) -> proto.Status {
	buf := make([]u8, proto.SETTING_MAX_SIZE + 16, context.temp_allocator)
	body := proto.encode_setting(buf, key, value)
	status, _ := ts_ask(t, ts, u, .Setting_Set, body)
	return status
}

@(test)
test_settings :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	laptop := logged_in(t, &ts, "alice")
	phone := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// To the account's other connections, and nobody else's.
	testing.expect_value(t, setting(t, &ts, laptop, "user/2", {1, 2, 3}), proto.Status.Ok)
	e, heard := has_event(ts_events(t, &ts, phone), .Setting_Changed)
	testing.expect(t, heard)
	key, value, ok := proto.decode_setting(e.body)
	testing.expect(t, ok && key == "user/2" && len(value) == 3 && value[2] == 3)
	_, heard = has_event(ts_events(t, &ts, laptop), .Setting_Changed)
	testing.expect(t, !heard)
	_, heard = has_event(ts_events(t, &ts, bob), .Setting_Changed)
	testing.expect(t, !heard)

	// Keys and values within bounds.
	testing.expect_value(t, setting(t, &ts, laptop, "User/2", {1}), proto.Status.Invalid)
	testing.expect_value(t, setting(t, &ts, laptop, "", {1}), proto.Status.Invalid)
	testing.expect_value(
		t,
		setting(
			t,
			&ts,
			laptop,
			"big",
			make([]u8, proto.MAX_SETTING_VALUE + 1, context.temp_allocator),
		),
		proto.Status.Too_Large,
	)
	testing.expect_value(
		t,
		setting(
			t,
			&ts,
			laptop,
			"big",
			make([]u8, proto.MAX_SETTING_VALUE, context.temp_allocator),
		),
		proto.Status.Ok,
	)

	// At most MAX_SETTINGS; one that's there may still change.
	key_buf: [16]u8
	for i in 2 ..< proto.MAX_SETTINGS {
		k := fmt_key(key_buf[:], i)
		testing.expect_value(t, setting(t, &ts, laptop, k, {1}), proto.Status.Ok)
	}
	testing.expect_value(t, setting(t, &ts, laptop, "one/more", {1}), proto.Status.Too_Large)
	testing.expect_value(t, setting(t, &ts, laptop, "user/2", {4}), proto.Status.Ok)
	// Removing one makes room, and is told.
	ts_events(t, &ts, phone)
	testing.expect_value(t, setting(t, &ts, laptop, "big", nil), proto.Status.Ok)
	e, heard = has_event(ts_events(t, &ts, phone), .Setting_Changed)
	key, value, _ = proto.decode_setting(e.body)
	testing.expect(t, heard && key == "big" && len(value) == 0)
	testing.expect_value(t, setting(t, &ts, laptop, "one/more", {1}), proto.Status.Ok)

	// A device that logs in later is told them all.
	later := ts_connect(&ts)
	status, _ := ts_login(t, &ts, later, "alice", "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	count := 0
	for ev in ts_events(t, &ts, later) {
		if ev.op == .Setting_Changed {
			k, v, _ := proto.decode_setting(ev.body)
			if k == "user/2" {
				testing.expect(t, len(v) == 1 && v[0] == 4)
			}
			count += 1
		}
	}
	testing.expect_value(t, count, proto.MAX_SETTINGS)
	// Bob has none.
	b2 := ts_connect(&ts)
	ts_login(t, &ts, b2, "bob", "a password")
	_, heard = has_event(ts_events(t, &ts, b2), .Setting_Changed)
	testing.expect(t, !heard)
}

@(private = "file")
fmt_key :: proc(buf: []u8, i: int) -> string {
	n := copy(buf, "key/")
	digits: [8]u8
	d := 0
	for v := i;; v /= 10 {
		digits[d] = u8('0' + v % 10)
		d += 1
		if v < 10 {
			break
		}
	}
	for j := d - 1; j >= 0; j -= 1 {
		buf[n] = digits[j]
		n += 1
	}
	return string(buf[:n])
}
