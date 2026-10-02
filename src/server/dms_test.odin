package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of direct messages, buddies and when people were last here, on
// the Test_Server of auth_test.odin.

// dm_open opens the DM with `other` as `u`.
@(private = "file")
dm_open_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	other: proto.Account_Id,
) -> (
	status: proto.Status,
	conv: proto.Conv_Id,
) {
	buf: [4]u8
	body: []u8
	status, body = ts_ask(t, ts, u, .DM_Open, proto.encode_account_id(&buf, other))
	if status == .Ok {
		ok: bool
		conv, ok = proto.decode_conv_id(body)
		testing.expect(t, ok)
	}
	return
}

// told_of is the conversation `conv` as a connection's events since the
// last time say it is, and whether they did, and whether a Msg_New came
// after it.
@(private = "file")
told_of :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> (
	record: proto.Conv,
	told: bool,
	message_after: bool,
) {
	for e in ts_events(t, ts, u) {
		#partial switch e.op {
		case .Conv_Changed:
			c, ok := proto.decode_conv(e.body)
			testing.expect(t, ok)
			if c.id == conv {
				record, told = c, true
			}
		case .Msg_New:
			m, ok := proto.decode_message(e.body)
			testing.expect(t, ok)
			if m.conv == conv && told {
				message_after = true
			}
		}
	}
	return
}

@(private = "file")
last_seen_of :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, account: proto.Account_Id) -> proto.Unix_Ms {
	ask := [1]proto.Account_Id{account}
	buf: [16]u8
	status, body := ts_ask(t, ts, u, .Last_Seen, proto.encode_last_seen_ask(buf[:], ask[:]))
	testing.expect_value(t, status, proto.Status.Ok)
	entries_buf: [4]proto.Last_Seen_Entry
	entries, ok := proto.decode_last_seen_answer(body, entries_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(entries), 1)
	if len(entries) != 1 {
		return 0
	}
	testing.expect_value(t, entries[0].account, account)
	return entries[0].time
}

@(test)
test_dm_open :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	alice_phone := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// Opened twice, and from both sides: one conversation.
	status, conv := dm_open_as(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	record, told, _ := told_of(t, &ts, alice, conv)
	testing.expect(t, told, "the one that opened it isn't told of it")
	testing.expect_value(t, record.kind, proto.Conv_Kind.DM)
	testing.expect_value(t, record.a, alice_acc.id)
	testing.expect_value(t, record.b, bob_acc.id)
	testing.expect(t, record.member)
	_, told, _ = told_of(t, &ts, alice_phone, conv)
	testing.expect(t, told, "the opener's other device isn't told of it")
	_, again := dm_open_as(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, again, conv)
	// Nothing said yet: nothing for bob to see.
	_, told, _ = told_of(t, &ts, bob, conv)
	testing.expect(t, !told, "bob was told of an empty DM")
	_, from_bob := dm_open_as(t, &ts, bob, alice_acc.id)
	testing.expect_value(t, from_bob, conv)
	testing.expect_value(t, len(s.convs.dms), 1)

	// Not with oneself, nor with nobody.
	status, _ = dm_open_as(t, &ts, alice, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = dm_open_as(t, &ts, alice, 999)
	testing.expect_value(t, status, proto.Status.Not_Found)
}

@(test)
test_dm_messages :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	conv: proto.Conv_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		alice_acc := ts_account(t, &ts, "alice", "a password")
		ts_account(t, &ts, "bob", "a password")
		ts_account(t, &ts, "carol", "a password")
		alice := logged_in(t, &ts, "alice")
		bob := logged_in(t, &ts, "bob")
		carol := logged_in(t, &ts, "carol")

		_, conv = dm_open_as(t, &ts, bob, alice_acc.id)
		ts_events(t, &ts, alice)

		// The first message is when alice hears of it: the conversation,
		// then the message, which is unread.
		status, first := post(t, &ts, bob, conv, "hello", 1)
		testing.expect_value(t, status, proto.Status.Ok)
		record, told, message_after := told_of(t, &ts, alice, conv)
		testing.expect(t, told, "alice wasn't told of the DM with its first message")
		testing.expect(t, message_after, "the message didn't come after the conversation")
		testing.expect_value(t, record.unread, 0)
		testing.expect_value(t, conv_record(&ts.s.convs, ts.s.convs.by_id[conv], alice_acc.id).unread, 1)
		status, _ = post(t, &ts, alice, conv, "hi", 2)
		testing.expect_value(t, status, proto.Status.Ok)
		_, told, _ = told_of(t, &ts, alice, conv)
		testing.expect(t, !told, "told of the DM again")

		// Nobody else may read or write it, or know it's there.
		status, _ = post(t, &ts, carol, conv, "me too", 3)
		testing.expect_value(t, status, proto.Status.Not_Found)
		status, _ = ts_ask(t, &ts, carol, .Msg_History, history_body(conv))
		testing.expect_value(t, status, proto.Status.Not_Found)
		buf: [proto.MARK_READ_SIZE]u8
		status, _ = ts_ask(t, &ts, carol, .Mark_Read, proto.encode_mark_read(&buf, conv, first))
		testing.expect_value(t, status, proto.Status.Not_Found)
		member_buf: [4]u8
		status, _ = ts_ask(t, &ts, carol, .Conv_Members, proto.encode_conv_id(&member_buf, conv))
		testing.expect_value(t, status, proto.Status.Not_Found)
		// Nor is it a channel.
		sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
		status, _ = ts_ask(t, &ts, carol, .Conv_Subscribe, proto.encode_conv_subscribe(&sub_buf, conv, true))
		testing.expect_value(t, status, proto.Status.Not_Found)
		room_buf: [4]u8
		status, _ = ts_ask(t, &ts, alice, .Voice_Join, proto.encode_room(&room_buf, proto.Room(conv)))
		testing.expect_value(t, status, proto.Status.Not_Found)
		for c in browse_all(t, &ts, alice) {
			testing.expect(t, c.id != conv, "a DM in the channel browser")
		}
	}

	// After a restart, both of them are told of it when they log in, and
	// it's still theirs alone.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	testing.expect_value(t, len(ts.s.convs.dms), 1)
	// The devices are known, and logged in as they connect, in the
	// order they first did.
	for name in ([]string{"alice", "bob"}) {
		u := ts_connect(&ts)
		testing.expect(t, u.account != nil && u.account.username == name)
		_, told, _ := told_of(t, &ts, u, conv)
		testing.expectf(t, told, "%s isn't told of the DM at login", name)
	}
	carol := ts_connect(&ts)
	testing.expect(t, carol.account != nil && carol.account.username == "carol")
	_, told, _ := told_of(t, &ts, carol, conv)
	testing.expect(t, !told, "carol is told of someone else's DM")
}

@(private = "file")
browse_all :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> []proto.Conv {
	status, body := ts_ask(t, ts, u, .Conv_Browse)
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Conv, proto.MAX_BROWSE_LIMIT, context.temp_allocator)
	_, convs, ok := proto.decode_browse_page(body, buf)
	testing.expect(t, ok)
	return convs
}

@(test)
test_last_seen :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")

	// Here: anyone may know.
	here := last_seen_of(t, &ts, carol, alice_acc.id)
	testing.expect(t, here > 0 && here != proto.LAST_SEEN_HIDDEN)
	// Never here: nobody has exchanged messages with them either.
	dave := ts_account(t, &ts, "dave", "a password")
	testing.expect_value(t, last_seen_of(t, &ts, alice, dave.id), proto.LAST_SEEN_HIDDEN)
	// No such account.
	testing.expect_value(t, last_seen_of(t, &ts, alice, 999), proto.Unix_Ms(0))

	_, conv := dm_open_as(t, &ts, bob, alice_acc.id)
	post(t, &ts, bob, conv, "are you there?", 1)
	ts_disconnect(&ts, alice)
	left := proto.Unix_Ms(alice_acc.last_seen)
	testing.expect(t, left > 0)

	// Only bob has written: alice's last time isn't his to know yet.
	testing.expect_value(t, last_seen_of(t, &ts, bob, alice_acc.id), proto.LAST_SEEN_HIDDEN)
	alice = logged_in(t, &ts, "alice")
	post(t, &ts, alice, conv, "yes", 2)
	ts_disconnect(&ts, alice)
	left = proto.Unix_Ms(alice_acc.last_seen)
	testing.expect_value(t, last_seen_of(t, &ts, bob, alice_acc.id), left)
	// And it never was carol's.
	testing.expect_value(t, last_seen_of(t, &ts, carol, alice_acc.id), proto.LAST_SEEN_HIDDEN)
	// Nor bob's to carol.
	ts_disconnect(&ts, bob)
	testing.expect_value(t, last_seen_of(t, &ts, carol, bob_acc.id), proto.LAST_SEEN_HIDDEN)

	status, _ := ts_ask(t, &ts, carol, .Last_Seen, []u8{1})
	testing.expect_value(t, status, proto.Status.Invalid)
}

@(test)
test_buddies :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	buddy_body :: proc(account: proto.Account_Id, on: bool) -> []u8 {
		buf := new([proto.BUDDY_SET_SIZE]u8, context.temp_allocator)
		return proto.encode_buddy(buf, account, on)
	}
	buddy_events :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (out: [dynamic][2]u32) {
		out = make([dynamic][2]u32, context.temp_allocator)
		for e in ts_events(t, ts, u) {
			if e.op == .Buddy_Changed {
				account, on, ok := proto.decode_buddy(e.body)
				testing.expect(t, ok)
				append(&out, [2]u32{u32(account), u32(on)})
			}
		}
		return
	}

	bob_id: proto.Account_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		alice_acc := ts_account(t, &ts, "alice", "a password")
		bob_id = ts_account(t, &ts, "bob", "a password").id
		carol_id := ts_account(t, &ts, "carol", "a password").id
		laptop := logged_in(t, &ts, "alice")
		phone := logged_in(t, &ts, "alice")
		bob := logged_in(t, &ts, "bob")

		// Every device of the account hears; bob doesn't.
		status, _ := ts_ask(t, &ts, laptop, .Buddy_Set, buddy_body(bob_id, true))
		testing.expect_value(t, status, proto.Status.Ok)
		ts_ask(t, &ts, laptop, .Buddy_Set, buddy_body(carol_id, true))
		ts_ask(t, &ts, phone, .Buddy_Set, buddy_body(carol_id, false))
		for u in ([]^Conn{laptop, phone}) {
			got := buddy_events(t, &ts, u)
			testing.expect_value(t, len(got), 3)
			if len(got) == 3 {
				testing.expect_value(t, got[0], [2]u32{u32(bob_id), 1})
				testing.expect_value(t, got[2], [2]u32{u32(carol_id), 0})
			}
		}
		testing.expect_value(t, len(buddy_events(t, &ts, bob)), 0)
		// Again changes nothing, and tells nobody.
		status, _ = ts_ask(t, &ts, laptop, .Buddy_Set, buddy_body(bob_id, true))
		testing.expect_value(t, status, proto.Status.Ok)
		testing.expect_value(t, len(buddy_events(t, &ts, phone)), 0)
		testing.expect_value(t, len(alice_acc.buddies), 1)

		status, _ = ts_ask(t, &ts, laptop, .Buddy_Set, buddy_body(alice_acc.id, true))
		testing.expect_value(t, status, proto.Status.Invalid)
		status, _ = ts_ask(t, &ts, laptop, .Buddy_Set, buddy_body(999, true))
		testing.expect_value(t, status, proto.Status.Not_Found)
	}

	// Kept: a device logging in after a restart is told.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	u := ts_connect(&ts)
	ts_login(t, &ts, u, "alice", "a password")
	got := buddy_events(t, &ts, u)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], [2]u32{u32(bob_id), 1})
	}
}

@(test)
test_file_offers :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	bob_phone := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	_, conv := dm_open_as(t, &ts, alice, bob.account.id)

	offer :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		conv: proto.Conv_Id,
		name: string,
		size: u64,
		nonce: u64,
	) -> (
		status: proto.Status,
		id: proto.Msg_Id,
	) {
		buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
		body := proto.encode_msg_post(buf, {conv = conv, nonce = nonce, kind = .File, text = name, file_size = size})
		answer: []u8
		status, answer = ts_ask(t, ts, u, .Msg_Post, body)
		if status == .Ok {
			id, _, _ = proto.decode_msg_posted(answer)
		}
		return
	}

	// Only what may be sent, only in a DM.
	status, _ := offer(t, &ts, alice, conv, "setup.exe", 100, 1)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = offer(t, &ts, alice, conv, "clip.mp4", 0, 2)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = offer(t, &ts, alice, s.convs.home.id, "clip.mp4", 100, 3)
	testing.expect_value(t, status, proto.Status.Invalid)

	id: proto.Msg_Id
	status, id = offer(t, &ts, alice, conv, "../holiday clip.mp4", 12345, 4)
	testing.expect_value(t, status, proto.Status.Ok)
	got: proto.Message
	for e in ts_events(t, &ts, bob_phone) {
		if e.op == .Msg_New {
			got, _ = proto.decode_message(e.body)
		}
	}
	testing.expect_value(t, got.id, id)
	testing.expect_value(t, got.kind, proto.Msg_Kind.File)
	testing.expect_value(t, got.file_name, "holiday clip.mp4")
	testing.expect_value(t, got.file_size, u64(12345))
	page_buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	_, body := ts_ask(t, &ts, bob, .Msg_History, history_body(conv))
	_, page, _ := proto.decode_history_page(body, page_buf)
	testing.expect_value(t, len(page), 1)
	if len(page) == 1 {
		testing.expect_value(t, page[0].file_name, "holiday clip.mp4")
		testing.expect_value(t, page[0].file_size, u64(12345))
	}

	// Only bob's devices may take it up; it's on alice's.
	o, ok := file_offer_for(s, bob, id)
	testing.expect(t, ok)
	testing.expect_value(t, o.sender, alice.key)
	testing.expect_value(t, o.from, alice_acc.id)
	_, ok = file_offer_for(s, bob_phone, id)
	testing.expect(t, ok)
	_, ok = file_offer_for(s, carol, id)
	testing.expect(t, !ok, "someone else could accept an offer")
	_, ok = file_offer_for(s, alice, id)
	testing.expect(t, !ok, "the sender could accept its own offer")

	// The file goes with the device it's on.
	ts_disconnect(&ts, alice)
	_, ok = file_offer_for(s, bob, id)
	testing.expect(t, !ok, "an offer outlived its sender")
}
