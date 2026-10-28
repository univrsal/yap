package server

import "core:os"
import "core:slice"
import "core:testing"

import "common:proto"

// Tests of groups, the DMs of a few accounts (see convs.odin), using the
// Test_Server from harness_test.odin.

@(private = "file")
group_open_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	others: ..proto.Account_Id,
) -> (
	status: proto.Status,
	conv: proto.Conv_Id,
) {
	// Written by hand, because encode_group_open refuses what the server
	// should be shown to refuse as well.
	request := make([dynamic]u8, context.temp_allocator)
	append(&request, u8(len(others)))
	for a in others {
		append(&request, u8(a), u8(a >> 8), u8(a >> 16), u8(a >> 24))
	}
	body: []u8
	status, body = ts_ask(t, ts, u, .Group_Open, request[:])
	if status == .Ok {
		ok: bool
		conv, ok = proto.decode_conv_id(body)
		testing.expect(t, ok)
	}
	return
}

// told_of returns the conversation `conv` as described by a connection's events
// since the last call, and whether the events mentioned it at all.
@(private = "file")
told_of :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> (
	record: proto.Conv,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op == .Conv_Changed {
			c, ok := proto.decode_conv(e.body)
			testing.expect(t, ok)
			if c.id == conv {
				record, told = c, true
			}
		}
	}
	return
}

@(test)
test_group_open :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	dave_acc := ts_account(t, &ts, "dave", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")

	status, conv := group_open_as(t, &ts, alice, carol_acc.id, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	record, told := told_of(t, &ts, alice, conv)
	testing.expect(t, told, "the one that opened it isn't told of it")
	testing.expect_value(t, record.kind, proto.Conv_Kind.Group)
	testing.expect(
		t,
		slice.equal(
			proto.conv_accounts(&record),
			[]proto.Account_Id{alice_acc.id, bob_acc.id, carol_acc.id},
		),
	)
	testing.expect(t, record.member)
	testing.expect_value(t, record.rights, proto.CONV_RIGHTS_ALL - {.Voice, .Speak, .Video})
	_, told = told_of(t, &ts, bob, conv)
	testing.expect(t, !told, "bob was told of an empty group")

	// The same people, opened by another of them and named in another order,
	// are the same group. One more person is another group.
	_, again := group_open_as(t, &ts, carol, alice_acc.id, bob_acc.id)
	testing.expect_value(t, again, conv)
	_, bigger := group_open_as(t, &ts, alice, bob_acc.id, carol_acc.id, dave_acc.id)
	testing.expect(t, bigger != 0 && bigger != conv)
	testing.expect_value(t, len(ts.s.convs.groups), 2)

	// Fewer than two others, oneself among them, someone twice or too many.
	status, _ = group_open_as(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = group_open_as(t, &ts, alice, bob_acc.id, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = group_open_as(t, &ts, alice, bob_acc.id, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = group_open_as(t, &ts, alice, 2, 3, 4, 5, 6, 7, 8, 9)
	testing.expect_value(t, status, proto.Status.Invalid)
	// Someone who doesn't exist.
	status, _ = group_open_as(t, &ts, alice, bob_acc.id, 999)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Bots can't be in a group, nor open one. (A bot logs in with a token, not
	// a password, so this one becomes a bot once it is logged in.)
	bot_acc := ts_account(t, &ts, "robot", "a password")
	bot := logged_in(t, &ts, "robot")
	bot_acc.flags += {.Bot}
	status, _ = group_open_as(t, &ts, alice, bob_acc.id, bot_acc.id)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = group_open_as(t, &ts, bot, alice_acc.id, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Denied)
}

@(test)
test_group_messages :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	conv: proto.Conv_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		ts_account(t, &ts, "alice", "a password")
		bob_acc := ts_account(t, &ts, "bob", "a password")
		ts_account(t, &ts, "carol", "a password")
		ts_account(t, &ts, "dave", "a password")
		alice := logged_in(t, &ts, "alice")
		bob := logged_in(t, &ts, "bob")
		carol := logged_in(t, &ts, "carol")
		dave := logged_in(t, &ts, "dave")
		carol_acc := carol.account

		_, conv = group_open_as(t, &ts, alice, bob_acc.id, carol_acc.id)
		ts_events(t, &ts, alice)

		// Everyone else hears of the group with its first message.
		status, first := post(t, &ts, alice, conv, "hello, you two", 1)
		testing.expect_value(t, status, proto.Status.Ok)
		for u in ([]^Conn{bob, carol}) {
			record, told := told_of(t, &ts, u, conv)
			testing.expectf(t, told, "%s wasn't told of the group", u.account.username)
			testing.expect_value(t, record.kind, proto.Conv_Kind.Group)
			testing.expect_value(t, len(proto.conv_accounts(&record)), 3)
		}
		testing.expect_value(
			t,
			conv_record(&ts.s.convs, ts.s.convs.by_id[conv], bob_acc.id).unread,
			1,
		)
		status, _ = post(t, &ts, carol, conv, "hi", 2)
		testing.expect_value(t, status, proto.Status.Ok)
		_, told := told_of(t, &ts, bob, conv)
		testing.expect(t, !told, "told of the group again")

		// Anyone in it may pin.
		testing.expect_value(t, pin_as(t, &ts, bob, first, true), proto.Status.Ok)

		// Nobody else can read it, write to it or know that it exists.
		status, _ = post(t, &ts, dave, conv, "me too", 3)
		testing.expect_value(t, status, proto.Status.Not_Found)
		status, _ = ts_ask(t, &ts, dave, .Msg_History, history_body(conv))
		testing.expect_value(t, status, proto.Status.Not_Found)
		member_buf: [4]u8
		status, _ = ts_ask(t, &ts, dave, .Conv_Members, proto.encode_conv_id(&member_buf, conv))
		testing.expect_value(t, status, proto.Status.Not_Found)
		sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
		status, _ = ts_ask(
			t,
			&ts,
			dave,
			.Conv_Subscribe,
			proto.encode_conv_subscribe(&sub_buf, conv, true),
		)
		testing.expect_value(t, status, proto.Status.Not_Found)

		// Its members can see who is in it, and it has no voice room.
		status, _ = ts_ask(t, &ts, bob, .Conv_Members, proto.encode_conv_id(&member_buf, conv))
		testing.expect_value(t, status, proto.Status.Ok)
		room_buf: [4]u8
		status, _ = ts_ask(
			t,
			&ts,
			alice,
			.Voice_Join,
			proto.encode_room(&room_buf, proto.Room(conv)),
		)
		testing.expect_value(t, status, proto.Status.Not_Found)

		// Files can't be offered in a group.
		file_buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
		status, _ = ts_ask(
			t,
			&ts,
			alice,
			.Msg_Post,
			proto.encode_msg_post(
				file_buf,
				{conv = conv, nonce = 4, kind = .File, text = "notes.txt", file_size = 10},
			),
		)
		testing.expect_value(t, status, proto.Status.Invalid)
	}

	// After a restart the group is still the group of the same three, and its
	// members are told about it when they log in.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	testing.expect_value(t, len(ts.s.convs.groups), 1)
	group := ts.s.convs.by_id[conv]
	testing.expect(t, group != nil && group.kind == .Group && len(group.members) == 3)
	testing.expect(t, group_find(&ts.s.convs, group.members[:]) == group)
	for name in ([]string{"alice", "bob", "carol"}) {
		u := ts_connect(&ts)
		testing.expect(t, u.account != nil && u.account.username == name)
		_, told := told_of(t, &ts, u, conv)
		testing.expectf(t, told, "%s isn't told of the group at login", name)
	}
	dave := ts_connect(&ts)
	_, told := told_of(t, &ts, dave, conv)
	testing.expect(t, !told, "dave is told of someone else's group")
}

@(test)
test_group_deleted_member :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	_, conv := group_open_as(t, &ts, alice, bob_acc.id, carol_acc.id)
	status, _ := post(t, &ts, alice, conv, "hello", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	group := ts.s.convs.by_id[conv]

	// A deleted member stays in the group, which goes on while two are left.
	testing.expect(t, account_erase(&ts.s, carol_acc))
	testing.expect_value(t, len(group.members), 3)
	testing.expect(t, group_find(&ts.s.convs, group.members[:]) == group)
	status, _ = post(t, &ts, alice, conv, "still here", 2)
	testing.expect_value(t, status, proto.Status.Ok)

	// With one left it can't be written to any more.
	testing.expect(t, account_erase(&ts.s, bob_acc))
	status, _ = post(t, &ts, alice, conv, "anyone?", 3)
	testing.expect_value(t, status, proto.Status.Denied)
}
