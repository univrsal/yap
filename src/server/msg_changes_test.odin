package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of editing, deleting and pinning messages, using the Test_Server from
// harness_test.odin.

@(private = "file")
pins_of :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> []proto.Message {
	buf: [4]u8
	status, body := ts_ask(t, ts, u, .Pins_Get, proto.encode_conv_id(&buf, conv))
	testing.expect_value(t, status, proto.Status.Ok)
	msgs := make([]proto.Message, proto.MAX_PINS, context.temp_allocator)
	got, ok := proto.decode_message_list(body, msgs)
	testing.expect(t, ok)
	return got
}

// changed returns the last Msg_Changed event about `id` that a connection was
// sent since its events were last read, and whether there was one.
@(private = "file")
changed :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
) -> (
	m: proto.Message,
	told: bool,
) {
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
	dir := test_dir(t)
	defer remove_tree(dir)
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

		// Only the author can edit a message, and only to non-empty text.
		testing.expect_value(t, edit_as(t, &ts, bob, id, "bob's words"), proto.Status.Denied)
		testing.expect_value(t, edit_as(t, &ts, alice, id, " \t"), proto.Status.Invalid)
		testing.expect_value(t, edit_as(t, &ts, alice, 999, "words"), proto.Status.Not_Found)
		testing.expect_value(t, edit_as(t, &ts, alice, id, "the words"), proto.Status.Ok)
		m, told := changed(t, &ts, bob, id)
		testing.expect(t, told, "bob wasn't told of the edit")
		testing.expect_value(t, m.text, "the words")
		testing.expect(t, m.edited > 0)

		// Line breaks are kept (though normalized) in both posts and
		// edits.
		lines: proto.Msg_Id
		_, lines = post(t, &ts, alice, home, "first\r\n  second  \n\n\n\n\nthird\n", 2)
		posted, found := msg_by_id(&ts.s, lines)
		testing.expect(t, found)
		testing.expect_value(t, posted.text, "first\n  second\n\n\nthird")
		testing.expect_value(
			t,
			edit_as(t, &ts, alice, lines, "first\nsecond\n\tthird"),
			proto.Status.Ok,
		)
		m, told = changed(t, &ts, bob, lines)
		testing.expect(t, told, "bob wasn't told of the edit")
		testing.expect_value(t, m.text, "first\nsecond\n third")
	}

	// The edit is persisted across a restart.
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
	dir := test_dir(t)
	defer remove_tree(dir)
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

	// Deleting a message's attached files along with it is tested in
	// attachments_test.odin.
	_, text := post(t, &ts, alice, home, "a secret", 2)
	_, bobs := post(t, &ts, bob, home, "bob's", 3)
	testing.expect_value(t, pin_as(t, &ts, admin, text, true), proto.Status.Ok)
	ts_events(t, &ts, bob)

	// Users can't delete somebody else's messages unless they have the
	// permission to.
	testing.expect_value(t, delete_as(t, &ts, alice, bobs), proto.Status.Denied)
	testing.expect_value(t, delete_as(t, &ts, admin, bobs), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, text), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, text), proto.Status.Ok) // no-op: already deleted
	m, told := changed(t, &ts, bob, text)
	testing.expect(t, told)
	testing.expect(t, .Deleted in m.flags && .Pinned not_in m.flags)
	testing.expect_value(t, m.text, "")

	// Nothing of the deleted messages is left to read.
	for id in ([]proto.Msg_Id{text, bobs}) {
		got, _ := msg_by_id(s, id)
		testing.expect(t, .Deleted in got.flags)
		testing.expect_value(t, got.text, "")
	}
	testing.expect_value(t, len(pins_of(t, &ts, bob, home)), 0)
	// They can't be edited or pinned again.
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

	// In a channel, only users with the permission to can pin messages.
	_, first := post(t, &ts, alice, home, "first", 1)
	testing.expect_value(t, pin_as(t, &ts, alice, first, true), proto.Status.Denied)
	testing.expect_value(t, pin_as(t, &ts, admin, first, true), proto.Status.Ok)
	m, told := changed(t, &ts, alice, first)
	testing.expect(t, told && .Pinned in m.flags)
	testing.expect_value(t, pin_as(t, &ts, admin, first, true), proto.Status.Ok)

	// In a DM, either participant can. Nobody else can even see the DM.
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

	// Pins are listed newest first, and there can be at most MAX_PINS.
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
