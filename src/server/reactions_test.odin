package server

import "core:fmt"
import "core:testing"

import "common:proto"

// Tests of reactions, on the Test_Server of auth_test.odin.

@(private = "file")
react_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	emoji: string,
	on: bool,
) -> proto.Status {
	buf := new([proto.MSG_REACT_MAX_SIZE]u8, context.temp_allocator)
	status, _ := ts_ask(t, ts, u, .Msg_React, proto.encode_msg_react(buf, id, emoji, on))
	return status
}

@(private = "file")
reaction_events :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
) -> [dynamic]proto.Reaction_Change {
	out := make([dynamic]proto.Reaction_Change, context.temp_allocator)
	for e in ts_events(t, ts, u) {
		if e.op == .Reaction_Changed {
			c, ok := proto.decode_reaction_changed(e.body)
			testing.expect(t, ok)
			append(&out, c)
		}
	}
	return out
}

@(test)
test_reactions :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home.id
	ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	append(&s.emoji.names, "party") // as if the folder had party.png
	defer {
		delete(s.emoji.names)
		s.emoji.names = nil
	}

	_, id := post(t, &ts, alice, home, "react to this", 1)
	ts_events(t, &ts, carol)
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍", true), proto.Status.Ok)
	got := reaction_events(t, &ts, carol)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(
			t,
			got[0],
			proto.Reaction_Change{id, home, "👍", 1, bob_acc.id, true},
		)
	}
	// Twice is once, and tells nobody.
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍", true), proto.Status.Ok)
	testing.expect_value(t, len(reaction_events(t, &ts, carol)), 0)
	testing.expect_value(t, react_as(t, &ts, carol, id, "👍", true), proto.Status.Ok)
	testing.expect_value(t, react_as(t, &ts, carol, id, ":party:", true), proto.Status.Ok)

	// Only emoji, and only the server's own of the :named: ones.
	testing.expect_value(t, react_as(t, &ts, bob, id, "hello", true), proto.Status.Invalid)
	testing.expect_value(t, react_as(t, &ts, bob, id, ":nope:", true), proto.Status.Invalid)
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍👍", true), proto.Status.Invalid)

	// Who asks sees their own marked; an event marks nobody's.
	_, body := ts_ask(t, &ts, bob, .Msg_History, history_body(home))
	page_buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	_, page, _ := proto.decode_history_page(body, page_buf)
	testing.expect_value(t, len(page), 1)
	if len(page) == 1 {
		rbuf: [proto.MAX_REACTIONS]proto.Reaction
		rs := proto.reactions_of(page[0], rbuf[:])
		// In the order they were first given, or for ties of the same
		// millisecond, of the emoji: which it is depends on the clock.
		testing.expect_value(t, len(rs), 2)
		if len(rs) == 2 {
			party, thumbs := rs[0], rs[1]
			if party.emoji != ":party:" {
				party, thumbs = thumbs, party
			}
			testing.expect_value(t, party, proto.Reaction{":party:", 1, false})
			testing.expect_value(t, thumbs, proto.Reaction{"👍", 2, true})
		}
	}

	// Taking one back that isn't there is nothing.
	ts_events(t, &ts, carol)
	testing.expect_value(t, react_as(t, &ts, bob, id, "🎉", false), proto.Status.Ok)
	testing.expect_value(t, len(reaction_events(t, &ts, carol)), 0)
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍", false), proto.Status.Ok)
	got = reaction_events(t, &ts, carol)
	testing.expect(t, len(got) == 1 && got[0].count == 1 && !got[0].on)

	// No more than so many kinds.
	for e in proto.EMOJI[:proto.MAX_REACTIONS - 2] {
		testing.expect_value(
			t,
			react_as(t, &ts, alice, id, fmt.tprintf("%r", e.r), true),
			proto.Status.Ok,
		)
	}
	testing.expect_value(t, react_as(t, &ts, alice, id, "🦄", true), proto.Status.Too_Large)
	// ... but more of a kind there is.
	testing.expect_value(t, react_as(t, &ts, alice, id, "👍", true), proto.Status.Ok)

	// Not where one can't read, nor on what's deleted, which loses them.
	buf: [4]u8
	_, dm_body := ts_ask(t, &ts, alice, .DM_Open, proto.encode_account_id(&buf, bob_acc.id))
	dm, _ := proto.decode_conv_id(dm_body)
	_, private := post(t, &ts, alice, dm, "between us", 2)
	testing.expect_value(t, react_as(t, &ts, carol, private, "👍", true), proto.Status.Not_Found)
	testing.expect_value(t, delete_as(t, &ts, alice, id), proto.Status.Ok)
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍", true), proto.Status.Invalid)
	m, _ := msg_by_id(s, id)
	testing.expect_value(t, m.reaction_count, 0)
}

// reactors asks who reacted with `emoji`; the accounts in the temp
// allocator.
@(private = "file")
reactors :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	id: proto.Msg_Id,
	emoji: string,
) -> (
	status: proto.Status,
	total: int,
	accounts: []proto.Account_Id,
) {
	buf := new([proto.REACTORS_GET_MAX_SIZE]u8, context.temp_allocator)
	body: []u8
	status, body = ts_ask(t, ts, u, .Reactors_Get, proto.encode_reactors_get(buf, id, emoji))
	if status != .Ok {
		return
	}
	got := new([proto.MAX_REACTORS]proto.Account_Id, context.temp_allocator)
	ok: bool
	total, accounts, ok = proto.decode_reactors(body, got)
	testing.expect(t, ok)
	return
}

@(test)
test_reactors :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home.id
	gaming := conv_by_name(&s.convs, "Gaming")
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")

	_, id := post(t, &ts, alice, home, "react to this", 1)
	testing.expect_value(t, react_as(t, &ts, bob, id, "👍", true), proto.Status.Ok)
	testing.expect_value(t, react_as(t, &ts, alice, id, "👍", true), proto.Status.Ok)
	testing.expect_value(t, react_as(t, &ts, carol, id, "🎉", true), proto.Status.Ok)
	// In the same millisecond, the lower account would come first.
	testing.expect(
		t,
		db_exec(
			&s.db,
			fmt.tprintf("UPDATE reactions SET time = time - 1000 WHERE account = %d", bob_acc.id),
		),
	)

	// The earliest first, and only that emoji's.
	status, total, accounts := reactors(t, &ts, carol, id, "👍")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, total, 2)
	testing.expect_value(t, len(accounts), 2)
	if len(accounts) == 2 {
		testing.expect_value(t, accounts[0], bob_acc.id)
		testing.expect_value(t, accounts[1], alice_acc.id)
	}
	// Nobody with that one.
	status, total, accounts = reactors(t, &ts, carol, id, "😀")
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, total, 0)
	// Not for whoever can't read it.
	testing.expect(t, conv_member_add(&s.convs, gaming, alice_acc.id))
	_, hidden := post(t, &ts, alice, gaming.id, "in Gaming", 2)
	testing.expect_value(t, react_as(t, &ts, alice, hidden, "👍", true), proto.Status.Ok)
	status, _, _ = reactors(t, &ts, bob, hidden, "👍")
	testing.expect_value(t, status, proto.Status.Not_Found)

	// More than an answer names: the first MAX_REACTORS, and how many.
	for i in 0 ..< proto.MAX_REACTORS + 5 {
		name := fmt.tprintf("user%d", i)
		ts_account(t, &ts, name, "a password")
		u := logged_in(t, &ts, name)
		testing.expect_value(t, react_as(t, &ts, u, id, "🎉", true), proto.Status.Ok)
	}
	status, total, accounts = reactors(t, &ts, bob, id, "🎉")
	testing.expect_value(t, total, proto.MAX_REACTORS + 6)
	testing.expect_value(t, len(accounts), proto.MAX_REACTORS)
}
