package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of when an account chose its activity and set its status, which
// clients connected to several servers use to keep the newest on all of them
// (proto.self_times): a copy from another server says when, and only replaces
// something older.

@(private = "file")
set_activity :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	a: proto.Activity,
	at: proto.Unix_Ms = 0,
) {
	buf: [proto.ACTIVITY_SET_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Activity_Set, proto.encode_activity(&buf, a, at))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(private = "file")
set_status :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	text: string,
	until: proto.Unix_Ms,
	at: proto.Unix_Ms = 0,
) {
	buf: [proto.ACCOUNT_BODY_MAX + proto.MAX_STATUS_SIZE + 8]u8
	body := proto.encode_profile_set(
		buf[:],
		{mask = proto.PROFILE_STATUS, status = text, status_until = until, status_at = at},
	)
	status, _ := ts_ask(t, ts, u, .Profile_Set, body)
	testing.expect_value(t, status, proto.Status.Ok)
}

// self_times_of returns the times in the last Self that `u` was sent.
@(private = "file")
self_times_of :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (activity_at, status_at: proto.Unix_Ms) {
	for e in ts_events(t, ts, u) {
		if e.op == .Self {
			activity_at, status_at = proto.self_times(e.body)
		}
	}
	return
}

@(test)
test_status_times :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer remove_tree(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	chosen_at, status_at: i64
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		acc := ts_account(t, &ts, "alice", "a password")
		alice := logged_in(t, &ts, "alice")
		ts_events(t, &ts, alice)
		testing.expect_value(t, acc.chosen_at, 0)

		// Chosen here: now.
		before := unix_ms()
		set_activity(t, &ts, alice, .Busy)
		testing.expect(t, acc.chosen_at >= before)
		at := proto.Unix_Ms(acc.chosen_at)
		// A copy of an older one is ignored, a newer one is taken as it is.
		set_activity(t, &ts, alice, .Online, at - 1000)
		testing.expect_value(t, acc.chosen, proto.Activity.Busy)
		set_activity(t, &ts, alice, .Away, at + 1000)
		testing.expect_value(t, acc.chosen, proto.Activity.Away)
		testing.expect_value(t, acc.chosen_at, i64(at + 1000))

		// The same for the status.
		set_status(t, &ts, alice, "lunch", 0)
		testing.expect(t, acc.status_at >= before)
		at = proto.Unix_Ms(acc.status_at)
		set_status(t, &ts, alice, "old", 0, at - 1)
		testing.expect_value(t, acc.status, "lunch")
		until := proto.Unix_Ms(unix_ms() + 60 * 60 * 1000)
		set_status(t, &ts, alice, "meeting", until, at + 5000)
		testing.expect_value(t, acc.status, "meeting")
		testing.expect_value(t, acc.status_until, i64(until))
		testing.expect_value(t, acc.status_at, i64(at + 5000))

		// The account's connections are told when.
		activity_at, self_status_at := self_times_of(t, &ts, alice)
		testing.expect_value(t, i64(activity_at), acc.chosen_at)
		testing.expect_value(t, i64(self_status_at), acc.status_at)
		chosen_at, status_at = acc.chosen_at, acc.status_at
	}

	// Both are kept, and a status that expires keeps the time it was set.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	acc := account_find(&ts.s.accounts, "alice")
	testing.expect_value(t, acc.chosen, proto.Activity.Away)
	testing.expect_value(t, acc.chosen_at, chosen_at)
	testing.expect_value(t, acc.status, "meeting")
	testing.expect_value(t, acc.status_at, status_at)
	statuses_expire(&ts.s, acc.status_until)
	testing.expect_value(t, acc.status, "")
	testing.expect_value(t, acc.status_at, status_at)
}
