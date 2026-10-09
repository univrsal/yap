package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of activity (activity.odin), on the Test_Server of auth_test.odin.

// seen_as is how `u` was last told `account` is, and whether it was told.
@(private = "file")
seen_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
) -> (
	a: proto.Activity,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op != .Account_Changed {
			continue
		}
		rec, ok := proto.decode_account(e.body)
		testing.expect(t, ok)
		if rec.id == account {
			a, told = rec.activity, true
		}
	}
	return
}

@(private = "file")
ask_activity :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, a: proto.Activity) {
	buf: [proto.ACTIVITY_SET_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Activity_Set, proto.encode_activity(&buf, a))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(private = "file")
ask_idle :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, idle: bool) {
	buf: [1]u8
	status, _ := ts_ask(t, ts, u, .Idle_Set, proto.encode_idle(&buf, idle))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_activity :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	bob_id: proto.Account_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		s := &ts.s
		ts_account(t, &ts, "alice", "a password")
		bob_acc := ts_account(t, &ts, "bob", "a password")
		bob_id = bob_acc.id
		alice := logged_in(t, &ts, "alice")
		ts_events(t, &ts, alice)
		bob := logged_in(t, &ts, "bob")

		// Coming is being online.
		a, told := seen_as(t, &ts, alice, bob_id)
		testing.expect(t, told)
		testing.expect_value(t, a, proto.Activity.Online)

		// Idle is away, and back is online again.
		ask_idle(t, &ts, bob, true)
		a, told = seen_as(t, &ts, alice, bob_id)
		testing.expect(t, told)
		testing.expect_value(t, a, proto.Activity.Away)
		ask_idle(t, &ts, bob, false)
		a, _ = seen_as(t, &ts, alice, bob_id)
		testing.expect_value(t, a, proto.Activity.Online)
		// Twice is once, and tells nobody.
		ask_idle(t, &ts, bob, false)
		_, told = seen_as(t, &ts, alice, bob_id)
		testing.expect(t, !told)

		// Busy, chosen: what bob's own connection is told it chose.
		ts_events(t, &ts, bob)
		ask_activity(t, &ts, bob, .Busy)
		a, _ = seen_as(t, &ts, alice, bob_id)
		testing.expect_value(t, a, proto.Activity.Busy)
		self_told := false
		for e in ts_events(t, &ts, bob) {
			if e.op == .Self {
				testing.expect_value(t, proto.self_activity(e.body), proto.Activity.Busy)
				self_told = true
			}
		}
		testing.expect(t, self_told)
		buf: [proto.ACTIVITY_SET_SIZE]u8
		status, _ := ts_ask(t, &ts, bob, .Activity_Set, []u8{9})
		testing.expect_value(t, status, proto.Status.Invalid)
		_ = buf

		// Appearing offline: so to alice, and not among who is here, but
		// for bob himself, or while his voice is in a room she sees.
		ask_activity(t, &ts, bob, .Offline)
		a, _ = seen_as(t, &ts, alice, bob_id)
		testing.expect_value(t, a, proto.Activity.Offline)
		users := []proto.User_Info {
			{num = alice.num, account = alice.account.id},
			{num = bob.num, account = bob_id},
		}
		hidden := []bool{false, appears_offline(bob.account)}
		testing.expect_value(t, len(users_seen_by(s, users, hidden, alice.account.id)), 1)
		testing.expect_value(t, len(users_seen_by(s, users, hidden, bob_id)), 2)
		in_room := []proto.User_Info {
			users[0],
			{num = bob.num, account = bob_id, room = proto.Room(s.convs.home.id)},
		}
		testing.expect_value(t, len(users_seen_by(s, in_room, hidden, alice.account.id)), 2)
		// Not here, as far as when he was last here goes.
		testing.expect(t, last_seen_by(s, alice.account, bob_id, 12345) != 12345)

		// Gone, and offline anyway.
		ask_activity(t, &ts, bob, .Online)
		a, _ = seen_as(t, &ts, alice, bob_id)
		testing.expect_value(t, a, proto.Activity.Online)
		ask_activity(t, &ts, bob, .Away)
		ts_disconnect(&ts, bob)
		a, _ = seen_as(t, &ts, alice, bob_id)
		testing.expect_value(t, a, proto.Activity.Offline)
	}

	// What bob chose is kept.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	bob := account_by_id(&ts.s.accounts, bob_id)
	testing.expect(t, bob != nil)
	testing.expect_value(t, bob.chosen, proto.Activity.Away)
	testing.expect_value(t, activity_of(bob), proto.Activity.Offline)
}
