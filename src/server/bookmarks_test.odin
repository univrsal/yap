package server

import "core:testing"

import "common:proto"

@(private = "file")
bookmark_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.BOOKMARK_SET_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Bookmark_Set, proto.encode_bookmark_set(&buf, id, on))
	return status
}

// bookmarks_of reads all of an account's bookmarks, a page at a time. They
// are allocated with the temp allocator.
@(private = "file")
bookmarks_of :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> []proto.Bookmark {
	all := make([dynamic]proto.Bookmark, context.temp_allocator)
	before_time: proto.Unix_Ms
	before: proto.Msg_Id
	for {
		buf: [proto.BOOKMARKS_GET_SIZE]u8
		status, body := ts_ask(
			t,
			ts,
			u,
			.Bookmarks_Get,
			proto.encode_bookmarks_get(&buf, before_time, before),
		)
		testing.expect_value(t, status, proto.Status.Ok)
		page := make([]proto.Bookmark, proto.BOOKMARKS_PAGE, context.temp_allocator)
		list, more, ok := proto.decode_bookmarks_page(body, page)
		testing.expect(t, ok)
		append(&all, ..list)
		if !more || len(list) == 0 {
			return all[:]
		}
		last := list[len(list) - 1]
		before_time, before = last.time, last.msg.id
	}
}

@(private = "file")
bookmark_ids :: proc(list: []proto.Bookmark) -> []proto.Msg_Id {
	ids := make([]proto.Msg_Id, len(list), context.temp_allocator)
	for b, i in list {
		ids[i] = b.msg.id
	}
	return ids
}

// told_bookmark returns the last Bookmark_Changed a connection was sent since
// its events were last read.
@(private = "file")
told_bookmark :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
) -> (
	id: proto.Msg_Id,
	on: bool,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op == .Bookmark_Changed {
			changed_id, _, changed_on, ok := proto.decode_bookmark_changed(e.body)
			testing.expect(t, ok)
			id, on, told = changed_id, changed_on, true
		}
	}
	return
}

// synced_bookmarks returns the Bookmarks event a new connection of an account
// is sent when it logs in.
@(private = "file")
synced_bookmarks :: proc(t: ^testing.T, ts: ^Test_Server, username: string) -> []proto.Msg_Id {
	u := ts_connect(ts)
	defer ts_disconnect(ts, u)
	status, _ := ts_login(t, ts, u, username, "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	e, found := has_event(ts_events(t, ts, u), .Bookmarks)
	testing.expect(t, found)
	buf := new([proto.MAX_BOOKMARKS]proto.Msg_Id, context.temp_allocator)
	ids, ok := proto.decode_bookmarks(e.body, buf)
	testing.expect(t, ok)
	return ids
}

@(test)
test_bookmarks :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home.id
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice := logged_in(t, &ts, "alice")
	alice2 := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	admin := logged_in(t, &ts, "admin")
	create_buf: [proto.CONV_CREATE_MAX_SIZE]u8
	_, created := ts_ask(
		t,
		&ts,
		admin,
		.Conv_Create,
		proto.encode_conv_create(create_buf[:], "secret", "", true, {}),
	)
	secret, _ := proto.decode_conv_id(created)
	member_buf: [proto.CONV_MEMBER_SET_SIZE]u8
	member_set :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		buf: ^[proto.CONV_MEMBER_SET_SIZE]u8,
		conv: proto.Conv_Id,
		acc: proto.Account_Id,
		on: bool,
	) {
		status, _ := ts_ask(
			t,
			ts,
			u,
			.Conv_Member_Set,
			proto.encode_conv_member_set(buf, conv, acc, on),
		)
		testing.expect_value(t, status, proto.Status.Ok)
	}
	member_set(t, &ts, admin, &member_buf, secret, alice_acc.id, true)

	_, first := post(t, &ts, bob, home, "first", 1)
	_, second := post(t, &ts, bob, home, "second", 2)
	_, hidden := post(t, &ts, admin, secret, "a secret", 3)
	_, gone := post(t, &ts, bob, home, "deleted", 4)
	testing.expect_value(t, delete_as(t, &ts, bob, gone), proto.Status.Ok)
	ts_events(t, &ts, alice)
	ts_events(t, &ts, alice2)

	// Bookmarking tells every connection of the account, and nobody else.
	testing.expect_value(t, bookmark_as(t, &ts, alice, first, true), proto.Status.Ok)
	for u in ([]^Conn{alice, alice2}) {
		id, on, told := told_bookmark(t, &ts, u)
		testing.expect(t, told && id == first && on)
	}
	_, _, bob_told := told_bookmark(t, &ts, bob)
	testing.expect(t, !bob_told)
	// Again is fine, and changes nothing.
	testing.expect_value(t, bookmark_as(t, &ts, alice, first, true), proto.Status.Ok)
	_, _, again := told_bookmark(t, &ts, alice)
	testing.expect(t, !again)
	testing.expect_value(t, bookmark_as(t, &ts, alice, second, true), proto.Status.Ok)
	testing.expect_value(t, bookmark_as(t, &ts, alice, hidden, true), proto.Status.Ok)

	// Only messages one can read, and not deleted ones.
	testing.expect_value(t, bookmark_as(t, &ts, bob, hidden, true), proto.Status.Not_Found)
	testing.expect_value(t, bookmark_as(t, &ts, bob, gone, true), proto.Status.Invalid)
	testing.expect_value(t, bookmark_as(t, &ts, bob, 999_999, true), proto.Status.Not_Found)

	// The newest bookmark first, each message as it is now.
	testing.expect_value(t, edit_as(t, &ts, bob, first, "first, edited"), proto.Status.Ok)
	list := bookmarks_of(t, &ts, alice)
	testing.expect_value(t, len(list), 3)
	if len(list) == 3 {
		testing.expect_value(t, list[0].msg.id, hidden)
		testing.expect_value(t, list[0].msg.conv, secret)
		testing.expect_value(t, list[2].msg.text, "first, edited")
		testing.expect(t, list[0].time >= list[2].time && list[2].time > 0)
	}
	testing.expect_value(t, len(bookmarks_of(t, &ts, bob)), 0)
	ids := synced_bookmarks(t, &ts, "alice")
	testing.expect(t, len(ids) == 3 && ids[0] == hidden && ids[2] == first)

	// A message deleted after it was bookmarked stays, as deleted.
	testing.expect_value(t, delete_as(t, &ts, bob, second), proto.Status.Ok)
	list = bookmarks_of(t, &ts, alice)
	testing.expect(t, len(list) == 3 && .Deleted in list[1].msg.flags)

	// Out of the channel, its message is left out of the list, and comes
	// back with the channel.
	member_set(t, &ts, admin, &member_buf, secret, alice_acc.id, false)
	ids = bookmark_ids(bookmarks_of(t, &ts, alice))
	testing.expect(t, len(ids) == 2 && ids[0] == second && ids[1] == first)
	member_set(t, &ts, admin, &member_buf, secret, alice_acc.id, true)
	testing.expect_value(t, len(bookmarks_of(t, &ts, alice)), 3)

	// Removing a bookmark is told about too, and works for anything.
	ts_events(t, &ts, alice)
	testing.expect_value(t, bookmark_as(t, &ts, alice, second, false), proto.Status.Ok)
	id, on, told := told_bookmark(t, &ts, alice)
	testing.expect(t, told && id == second && !on)
	testing.expect_value(t, bookmark_as(t, &ts, alice, 999_999, false), proto.Status.Ok)

	// A purged message takes its bookmarks with it.
	testing.expect(t, db_write(&s.db, .Msg_Remove, i64(hidden)))
	ids = synced_bookmarks(t, &ts, "alice")
	testing.expect(t, len(ids) == 1 && ids[0] == first)

	// The list comes a page at a time, and has room for MAX_BOOKMARKS.
	for i in 1 ..< proto.MAX_BOOKMARKS {
		_, more := post(t, &ts, bob, home, "more", u64(100 + i))
		testing.expect_value(t, bookmark_as(t, &ts, alice, more, true), proto.Status.Ok)
	}
	_, too_many := post(t, &ts, bob, home, "one too many", 100_000)
	testing.expect_value(t, bookmark_as(t, &ts, alice, too_many, true), proto.Status.Too_Large)
	list = bookmarks_of(t, &ts, alice)
	testing.expect_value(t, len(list), proto.MAX_BOOKMARKS)
	testing.expect_value(t, list[len(list) - 1].msg.id, first)
	testing.expect_value(t, len(synced_bookmarks(t, &ts, "alice")), proto.MAX_BOOKMARKS)
}
