package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of tracking what accounts have read, using the Test_Server from
// auth_test.odin.

// read_state returns the state from the last Read_Changed event a connection
// was sent, and whether there was one.
read_state :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
) -> (
	state: proto.Read_State,
	told: bool,
) {
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
	defer remove_tree(dir)
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

		// When messages are read on one device, every device of the account
		// is told.
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
		// Marking an older message, or the same one again, as read changes
		// nothing, and nobody is told.
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, 1))
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, last - 1))
		_, told := read_state(t, &ts, phone)
		testing.expect(t, !told)
		testing.expect_value(t, home.reads[laptop.account.id].read, last - 1)
		// Marking past the last message only marks up to the last message.
		ts_ask(t, &ts, laptop, .Mark_Read, mark_body(home.id, last + 1000))
		testing.expect_value(t, home.reads[laptop.account.id].read, last)

		// Alice's own post marks everything before it as read.
		for i in 0 ..< 2 {
			post(t, &ts, bob, home.id, "more news", u64(20 + i))
		}
		testing.expect_value(t, conv_record(&s.convs, home, laptop.account.id).unread, 2)
		_, mine := post(t, &ts, laptop, home.id, "read it", 1)
		state, told2 := read_state(t, &ts, phone)
		testing.expect(t, told2)
		testing.expect_value(t, state.read, mine)
		testing.expect_value(t, state.unread, 0)
		// ... and is unread for bob, since it came after his last post.
		testing.expect_value(t, conv_record(&s.convs, home, bob.account.id).unread, 1)

		// The unread count stops at UNREAD_CAP.
		for i in 0 ..< proto.UNREAD_CAP + 20 {
			post(t, &ts, bob, home.id, "flood", u64(100 + i))
		}
		testing.expect_value(
			t,
			conv_record(&s.convs, home, laptop.account.id).unread,
			proto.UNREAD_CAP,
		)

		// Only members can mark messages as read, and subscribing starts
		// with everything marked as read.
		gaming := conv_by_name(&s.convs, "Gaming")
		testing.expect(t, conv_member_add(&s.convs, gaming, bob.account.id))
		post(t, &ts, bob, gaming.id, "in gaming", 500)
		post(t, &ts, bob, gaming.id, "still in gaming", 501)
		status, _ = ts_ask(t, &ts, laptop, .Mark_Read, mark_body(gaming.id, 1))
		testing.expect_value(t, status, proto.Status.Denied)
		sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
		ts_ask(
			t,
			&ts,
			laptop,
			.Conv_Subscribe,
			proto.encode_conv_subscribe(&sub_buf, gaming.id, true),
		)
		record = conv_record(&s.convs, gaming, laptop.account.id)
		testing.expect_value(t, record.read, gaming.last_msg)
		testing.expect_value(t, record.unread, 0)

		// A channel's notification level can be set, and every device of
		// the account is told.
		ts_events(t, &ts, phone)
		notify_buf: [proto.CONV_NOTIFY_SIZE]u8
		status, _ = ts_ask(
			t,
			&ts,
			laptop,
			.Conv_Notify,
			proto.encode_conv_notify(&notify_buf, home.id, .None),
		)
		testing.expect_value(t, status, proto.Status.Ok)
		e, changed := has_event(ts_events(t, &ts, phone), .Conv_Changed)
		testing.expect(t, changed)
		conv, _ := proto.decode_conv(e.body)
		testing.expect_value(t, conv.notify, proto.Notify_Level.None)
		testing.expect_value(t, conv.unread, proto.UNREAD_CAP)
		db_commit(&ts.s.db)
	}

	// Everything is still the same after a restart.
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
