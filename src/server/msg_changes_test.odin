package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of editing, deleting and pinning, on the Test_Server of
// auth_test.odin.

edit_as :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id, text: string) -> proto.Status {
	buf := new([proto.MSG_EDIT_MAX_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Edit, proto.encode_msg_edit(buf, id, text))
	return status
}

delete_as :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id) -> proto.Status {
	buf := new([proto.MSG_ID_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Delete, proto.encode_msg_id(buf, id))
	return status
}

@(private = "file")
pin_as :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id, on: bool) -> proto.Status {
	buf := new([proto.MSG_PIN_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_Pin, proto.encode_msg_pin(buf, id, on))
	return status
}

@(private = "file")
pins_of :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id) -> []proto.Message {
	buf: [4]u8
	status, body := ts_ask(t, ts, u, .Pins_Get, proto.encode_conv_id(&buf, conv))
	testing.expect_value(t, status, proto.Status.Ok)
	msgs := make([]proto.Message, proto.MAX_PINS, context.temp_allocator)
	got, ok := proto.decode_message_list(body, msgs)
	testing.expect(t, ok)
	return got
}

// changed is the last Msg_Changed a connection was sent about `id`
// since the last look, and whether there was one.
@(private = "file")
changed :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id) -> (m: proto.Message, told: bool) {
	for e in ts_events(t, ts, u) {
		if e.op != .Msg_Changed {
			continue
		}
		got, ok := proto.decode_message(e.body)
		testing.expect(t, ok)
		if got.id == id {
			m, told = got, true
		}
	}
	return
}

@(test)
test_edit :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)

	id: proto.Msg_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		home := ts.s.convs.home.id
		ts_account(t, &ts, "alice", "a password")
		ts_account(t, &ts, "bob", "a password")
		alice := logged_in(t, &ts, "alice")
		bob := logged_in(t, &ts, "bob")
		_, id = post(t, &ts, alice, home, "teh words", 1)
		ts_events(t, &ts, bob)

		// Only the author, only to something.
		testing.expect_value(t, edit_as(t, &ts, bob, id, "bob's words"), proto.Status.Denied)
		testing.expect_value(t, edit_as(t, &ts, alice, id, " \t"), proto.Status.Invalid)
		testing.expect_value(t, edit_as(t, &ts, alice, 999, "words"), proto.Status.Not_Found)
		testing.expect_value(t, edit_as(t, &ts, alice, id, "the words"), proto.Status.Ok)
		m, told := changed(t, &ts, bob, id)
		testing.expect(t, told, "bob wasn't told of the edit")
		testing.expect_value(t, m.text, "the words")
		testing.expect(t, m.edited > 0)

		// Lines stay, on posts and edits.
		lines: proto.Msg_Id
		_, lines = post(t, &ts, alice, home, "first\r\n  second  \n\n\n\n\nthird\n", 2)
		posted, found := msg_by_id(&ts.s, lines)
		testing.expect(t, found)
		testing.expect_value(t, posted.text, "first\n  second\n\n\nthird")
		testing.expect_value(t, edit_as(t, &ts, alice, lines, "first\nsecond\n\tthird"), proto.Status.Ok)
		m, told = changed(t, &ts, bob, lines)
		testing.expect(t, told, "bob wasn't told of the edit")
		testing.expect_value(t, m.text, "first\nsecond\n third")
	}

	// Kept.
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	m, found := msg_by_id(&ts.s, id)
	testing.expect(t, found)
	testing.expect_value(t, m.text, "the words")
	testing.expect(t, m.edited > 0)
}

@(test)
test_delete :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	home := s.convs.home.id
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// A picture, which nobody can fetch once its message is gone.
	jpeg := test_jpeg(64, 48, 3)
	put := proto.Blob_Put {
		kind   = .Image,
		size   = len(jpeg),
		hash   = blob_hash(jpeg),
		width  = 64,
		height = 48,
	}
	blob, stored := upload(t, &ts, alice, jpeg, put)
	testing.expect(t, stored)
	post_buf: [proto.MSG_POST_MAX_SIZE]u8
	status, answer := ts_ask(t, &ts, alice, .Msg_Post, proto.encode_msg_post(post_buf[:], {conv = home, nonce = 1, kind = .Image, blob = blob}))
	testing.expect_value(t, status, proto.Status.Ok)
	picture, _, _ := proto.decode_msg_posted(answer)
	id_buf: [proto.BLOB_GET_SIZE]u8
	status, _ = ts_ask(t, &ts, bob, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Ok)
	_, text := post(t, &ts, alice, home, "a secret", 2)
	_, bobs := post(t, &ts, bob, home, "bob's", 3)
	testing.expect_value(t, pin_as(t, &ts, admin, text, true), proto.Status.Ok)
	ts_events(t, &ts, bob)

	// Not somebody else's, unless one may.
	testing.expect_value(t, delete_as(t, &ts, alice, bobs), proto.Status.Denied)
	testing.expect_value(t, delete_as(t, &ts, admin, bobs), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, picture), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, text), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, text), proto.Status.Ok) // again: nothing to do
	m, told := changed(t, &ts, bob, text)
	testing.expect(t, told)
	testing.expect(t, .Deleted in m.flags && .Pinned not_in m.flags)
	testing.expect_value(t, m.text, "")

	// Nothing of them is left to read or fetch.
	for id in ([]proto.Msg_Id{picture, text, bobs}) {
		got, _ := msg_by_id(s, id)
		testing.expect(t, .Deleted in got.flags)
		testing.expect_value(t, got.text, "")
		testing.expect_value(t, got.image.blob, proto.Blob_Id(0))
	}
	status, _ = ts_ask(t, &ts, bob, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = ts_ask(t, &ts, alice, .Blob_Get, proto.encode_blob_id(&id_buf, blob))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect_value(t, len(pins_of(t, &ts, bob, home)), 0)
	// Nor edited, nor pinned again.
	testing.expect_value(t, edit_as(t, &ts, alice, text, "back"), proto.Status.Invalid)
	testing.expect_value(t, pin_as(t, &ts, admin, text, true), proto.Status.Invalid)
	// And they don't count as unread.
	testing.expect_value(t, conv_record(&s.convs, s.convs.home, bob.account.id).unread, 0)
}

@(test)
test_pins :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home.id
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	admin := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")

	// In a channel, those who may.
	_, first := post(t, &ts, alice, home, "first", 1)
	testing.expect_value(t, pin_as(t, &ts, alice, first, true), proto.Status.Denied)
	testing.expect_value(t, pin_as(t, &ts, admin, first, true), proto.Status.Ok)
	m, told := changed(t, &ts, alice, first)
	testing.expect(t, told && .Pinned in m.flags)
	testing.expect_value(t, pin_as(t, &ts, admin, first, true), proto.Status.Ok)

	// In a DM, either of the two; nobody else even sees it.
	buf: [4]u8
	_, body := ts_ask(t, &ts, alice, .DM_Open, proto.encode_account_id(&buf, bob_acc.id))
	dm, _ := proto.decode_conv_id(body)
	_, said := post(t, &ts, alice, dm, "remember this", 2)
	testing.expect_value(t, pin_as(t, &ts, bob, said, true), proto.Status.Ok)
	testing.expect_value(t, pin_as(t, &ts, carol, said, true), proto.Status.Not_Found)
	testing.expect_value(t, pin_as(t, &ts, admin, said, false), proto.Status.Not_Found)
	status, _ := ts_ask(t, &ts, carol, .Pins_Get, proto.encode_conv_id(&buf, dm))
	testing.expect_value(t, status, proto.Status.Not_Found)
	testing.expect_value(t, len(pins_of(t, &ts, alice, dm)), 1)

	// Newest pin first, and no more than there may be.
	for i in 0 ..< proto.MAX_PINS - 1 {
		_, id := post(t, &ts, alice, home, "more", u64(10 + i))
		testing.expect_value(t, pin_as(t, &ts, admin, id, true), proto.Status.Ok)
	}
	_, one_more := post(t, &ts, alice, home, "one too many", 100)
	testing.expect_value(t, pin_as(t, &ts, admin, one_more, true), proto.Status.Too_Large)
	pins := pins_of(t, &ts, alice, home)
	testing.expect_value(t, len(pins), proto.MAX_PINS)
	testing.expect_value(t, pins[len(pins) - 1].id, first)
	testing.expect_value(t, pins[len(pins) - 1].text, "first")

	// Unpinning makes room.
	testing.expect_value(t, pin_as(t, &ts, admin, first, false), proto.Status.Ok)
	testing.expect_value(t, pin_as(t, &ts, admin, one_more, true), proto.Status.Ok)
	got, _ := msg_by_id(s, first)
	testing.expect(t, .Pinned not_in got.flags)
}
