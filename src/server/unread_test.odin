package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of what accounts have read, on the Test_Server of auth_test.odin.

// read_state is what the last Read_Changed a connection was sent says,
// and whether it was sent one.
read_state :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (state: proto.Read_State, told: bool) {
	for e in ts_events(t, ts, u) {
		if e.op == .Read_Changed {
			ok: bool
			state, ok = proto.decode_read_changed(e.body)
			testing.expect(t, ok)
			told = true
		}
	}
	return
}

mark_body :: proc(conv: proto.Conv_Id, id: proto.Msg_Id) -> []u8 {
	buf := new([proto.MARK_READ_SIZE]u8, context.temp_allocator)
	return proto.encode_mark_read(buf, conv, id)
}

@(test)
test_unread :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		s := &ts.s
		ts_account(t, &ts, "alice", "a password")
		ts_account(t, &ts, "bob", "a password")
		laptop := logged_in(t, &ts, "alice")
		phone := logged_in(t, &ts, "alice")
		bob := logged_in(t, &ts, "bob")
		home := s.convs.home

		// Bob's messages are unread for alice, not for bob.
		last: proto.Msg_Id
		for i in 0 ..< 3 {
			_, last = post(t, &ts, bob, home.id, "news", u64(10 + i))
		}
		record := conv_record(&s.convs, home, laptop.account.id)
		testing.expect_value(t, record.unread, 3)
		testing.expect_value(t, record.read, proto.Msg_Id(0))
		testing.expect_value(t, conv_record(&s.convs, home, bob.account.id).unread, 0)
		testing.expect_value(t, conv_record(&s.convs, home, bob.account.id).read, last)

		// Reading on one device: every device of the account is told.
		ts_events(t, &ts, laptop)
		ts_events(t, &ts, phone)
		status, _ := ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, last - 1))
		testing.expect_value(t, status, proto.Status.Ok)
		for u in ([]^Conn{laptop, phone}) {
			state, told := read_state(t, &ts, u)
			testing.expect(t, told)
			testing.expect_value(t, state.read, last - 1)
			testing.expect_value(t, state.unread, 1)
		}
		// Back in time, or again, is nothing, and no news.
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, 1))
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, last - 1))
		_, told := read_state(t, &ts, phone)
		testing.expect(t, !told)
		testing.expect_value(t, home.reads[laptop.account.id].read, last - 1)
		// Past the end is as far as the end.
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, last + 1000))
		testing.expect_value(t, home.reads[laptop.account.id].read, last)

		// Alice's own post reads everything before it.
		for i in 0 ..< 2 {
			post(t, &ts, bob, home.id, "more news", u64(20 + i))
		}
		testing.expect_value(t, conv_record(&s.convs, home, laptop.account.id).unread, 2)
		_, mine := post(t, &ts, laptop, home.id, "read it", 1)
		state, told2 := read_state(t, &ts, phone)
		testing.expect(t, told2)
		testing.expect_value(t, state.read, mine)
		testing.expect_value(t, state.unread, 0)
		// ... and is unread for bob, whose last post it came after.
		testing.expect_value(t, conv_record(&s.convs, home, bob.account.id).unread, 1)

		// Counting stops at the cap.
		for i in 0 ..< proto.UNREAD_CAP + 20 {
			post(t, &ts, bob, home.id, "flood", u64(100 + i))
		}
		testing.expect_value(t, conv_record(&s.convs, home, laptop.account.id).unread, proto.UNREAD_CAP)

		// Only a member reads, and subscribing starts with everything read.
		gaming := conv_by_name(&s.convs, "Gaming")
		testing.expect(t, conv_member_add(&s.convs, gaming, bob.account.id))
		post(t, &ts, bob, gaming.id, "in gaming", 500)
		post(t, &ts, bob, gaming.id, "still in gaming", 501)
		status, _ = ts_ask(t, &ts, laptop, .Mark_Read, mark_body(gaming.id, 1))
		testing.expect_value(t, status, proto.Status.Denied)
		sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
		ts_ask(t, &ts, laptop, .Conv_Subscribe, proto.encode_conv_subscribe(&sub_buf, gaming.id, true))
		record = conv_record(&s.convs, gaming, laptop.account.id)
		testing.expect_value(t, record.read, gaming.last_msg)
		testing.expect_value(t, record.unread, 0)

		// How much a channel may interrupt: set, and told to every device.
		ts_events(t, &ts, phone)
		notify_buf: [proto.CONV_NOTIFY_SIZE]u8
		status, _ = ts_ask(t, &ts, laptop, .Conv_Notify, proto.encode_conv_notify(&notify_buf, home.id, .None))
		testing.expect_value(t, status, proto.Status.Ok)
		e, changed := has_event(ts_events(t, &ts, phone), .Conv_Changed)
		testing.expect(t, changed)
		conv, _ := proto.decode_conv(e.body)
		testing.expect_value(t, conv.notify, proto.Notify_Level.None)
		testing.expect_value(t, conv.unread, proto.UNREAD_CAP)
		db_commit(&ts.s.db)
	}

	// After a restart, the same.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	s := &ts.s
	alice := account_find(&s.accounts, "alice")
	record := conv_record(&s.convs, s.convs.home, alice.id)
	testing.expect_value(t, record.unread, proto.UNREAD_CAP)
	testing.expect_value(t, record.notify, proto.Notify_Level.None)
	testing.expect(t, record.read != 0)
}
