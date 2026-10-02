package server

import "core:testing"

import "common:proto"

// Tests of threads, on the Test_Server of auth_test.odin.

@(private = "file")
reply :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
	text: string,
	nonce: u64,
) -> (
	status: proto.Status,
	id: proto.Msg_Id,
) {
	buf := make([]u8, proto.MSG_POST_MAX_SIZE, context.temp_allocator)
	body := proto.encode_msg_post(buf, {conv = conv, nonce = nonce, thread_root = root, kind = .Text, text = text})
	answer: []u8
	status, answer = ts_ask(t, ts, u, .Msg_Post, body)
	if status == .Ok {
		ok: bool
		id, _, ok = proto.decode_msg_posted(answer)
		testing.expect(t, ok)
	}
	return
}

@(private = "file")
page :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	root: proto.Msg_Id,
	anchor: proto.Msg_Id = 0,
	dir := proto.History_Dir.Before,
	limit := proto.MAX_HISTORY_LIMIT,
) -> (
	status: proto.Status,
	msgs: []proto.Message,
) {
	buf := new([proto.MSG_HISTORY_SIZE]u8, context.temp_allocator)
	body: []u8
	status, body = ts_ask(
		t,
		ts,
		u,
		.Msg_History,
		proto.encode_msg_history(buf, {conv = conv, thread_root = root, anchor = anchor, dir = dir, limit = limit}),
	)
	if status != .Ok {
		return
	}
	list := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	ok: bool
	_, msgs, ok = proto.decode_history_page(body, list)
	testing.expect(t, ok)
	return
}

// root_told is the last Msg_Changed a connection was sent about `id`
// since the last look.
@(private = "file")
root_told :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, id: proto.Msg_Id) -> (m: proto.Message, told: bool) {
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
test_threads :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	_, root := post(t, &ts, alice, home, "a question", 1)
	_, other := post(t, &ts, alice, home, "something else", 2)
	_, elsewhere := post(t, &ts, alice, gaming.id, "in gaming", 3)
	ts_events(t, &ts, bob)

	// A reply: the root is told it has one.
	status, first := reply(t, &ts, bob, home, root, "an answer", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	m, told := root_told(t, &ts, bob, root)
	testing.expect(t, told, "the root wasn't changed")
	testing.expect(t, .Has_Thread in m.flags)
	testing.expect_value(t, m.reply_count, 1)
	testing.expect_value(t, m.last_reply, first)
	r, _ := msg_by_id(s, first)
	testing.expect_value(t, r.thread_root, root)

	// A reply to a reply is the root's.
	second: proto.Msg_Id
	status, second = reply(t, &ts, alice, home, first, "another", 4)
	testing.expect_value(t, status, proto.Status.Ok)
	r, _ = msg_by_id(s, second)
	testing.expect_value(t, r.thread_root, root)
	m, _ = msg_by_id(s, root)
	testing.expect_value(t, m.reply_count, 2)
	testing.expect_value(t, m.last_reply, second)

	// Not to something in another conversation, or not there.
	status, _ = reply(t, &ts, alice, home, elsewhere, "wrong place", 5)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = reply(t, &ts, alice, home, 999, "nowhere", 6)
	testing.expect_value(t, status, proto.Status.Invalid)

	// The conversation's history has the replies; the thread's only its
	// own, oldest first like any page.
	_, msgs := page(t, &ts, bob, home, 0)
	ids := make([dynamic]proto.Msg_Id, context.temp_allocator)
	for x in msgs {
		append(&ids, x.id)
	}
	testing.expect_value(t, len(ids), 4)
	_, msgs = page(t, &ts, bob, home, root)
	testing.expect_value(t, len(msgs), 2)
	if len(msgs) == 2 {
		testing.expect_value(t, msgs[0].id, first)
		testing.expect_value(t, msgs[1].id, second)
	}
	_, msgs = page(t, &ts, bob, home, root, first, .After)
	testing.expect_value(t, len(msgs), 1)
	_, msgs = page(t, &ts, bob, home, other)
	testing.expect_value(t, len(msgs), 0)

	// A thread is asked for by its root, in its conversation.
	status, _ = page(t, &ts, bob, home, first)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = page(t, &ts, alice, gaming.id, root)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = page(t, &ts, alice, home, 999)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Deleting a reply counts again.
	ts_events(t, &ts, bob)
	testing.expect_value(t, delete_as(t, &ts, alice, second), proto.Status.Ok)
	m, told = root_told(t, &ts, bob, root)
	testing.expect(t, told, "the root wasn't changed by the delete")
	testing.expect_value(t, m.reply_count, 1)
	testing.expect_value(t, m.last_reply, first)
	testing.expect(t, .Has_Thread in m.flags)
	testing.expect_value(t, delete_as(t, &ts, bob, first), proto.Status.Ok)
	m, _ = msg_by_id(s, root)
	testing.expect_value(t, m.reply_count, 0)
	testing.expect_value(t, m.last_reply, 0)
	// Its deleted replies are still in it, so it still has a thread.
	testing.expect(t, .Has_Thread in m.flags)

	// A deleted root takes no more replies.
	testing.expect_value(t, delete_as(t, &ts, alice, root), proto.Status.Ok)
	status, _ = reply(t, &ts, bob, home, root, "too late", 7)
	testing.expect_value(t, status, proto.Status.Invalid)

	// A reply isn't pinned, by whoever may pin.
	ts_account(t, &ts, "admin", "a password", {.Owner})
	admin := logged_in(t, &ts, "admin")
	_, root2 := post(t, &ts, alice, home, "again", 8)
	_, third := reply(t, &ts, bob, home, root2, "yes", 9)
	buf: [proto.MSG_PIN_SIZE]u8
	status, _ = ts_ask(t, &ts, admin, .Msg_Pin, proto.encode_msg_pin(&buf, third, true))
	testing.expect_value(t, status, proto.Status.Invalid)
}
