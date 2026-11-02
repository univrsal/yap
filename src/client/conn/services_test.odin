#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of searching (search.odin), invite codes (invites.odin) and activity
// (activity.odin): what each asks of the server, what is shown when the
// answer arrives, and what is dropped because it is out of date.

@(private = "file")
open_service :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_conv(tc, 3, "Lobby")
	tc_conv(tc, 4, "Gaming")
	return tc_view(tc)
}

// ---- search ----

@(private = "file")
answer_body :: proc(searched_to: proto.Msg_Id, more: u8, msgs: []proto.Message) -> []u8 {
	out := make([]u8, 8192, context.temp_allocator)
	body, _ := proto.encode_search_answer(out, searched_to, more, msgs)
	return body
}

@(private = "file")
hit :: proc(id: proto.Msg_Id, conv: proto.Conv_Id, text: string) -> proto.Message {
	return {id = id, conv = conv, sender = 2, time = proto.Unix_Ms(id), kind = .Text, text = text}
}

@(test)
test_search_pages :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)
	defer search_destroy(&tc.c)
	c := &tc.c
	c.convs.viewing = 3

	search_start(c, {query = "  hello world  "})
	r, ok := tc_one(t, &tc, .Msg_Search)
	testing.expect(t, ok)
	s, dec := proto.decode_msg_search(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, s.query, "hello world")
	testing.expect_value(t, s.conv, proto.Conv_Id(3)) // the conversation being looked at
	testing.expect_value(t, s.before, proto.Msg_Id(0))
	testing.expect_value(t, s.limit, SEARCH_PAGE)
	testing.expect(t, v.search.loading)
	testing.expect_value(t, v.search.query, "hello world")

	tc_answer(
		&tc,
		r.id,
		.Ok,
		answer_body(70, proto.MORE_BEFORE, {hit(90, 3, "hello there"), hit(80, 3, "world, hello")}),
	)
	testing.expect_value(t, len(v.search.found), 2)
	testing.expect(t, v.search.more && !v.search.loading)
	testing.expect_value(t, v.search.error, "")
	if len(v.search.found) == 2 {
		testing.expect_value(t, v.search.found[0].msg.text, "hello there")
		testing.expect_value(t, v.search.found[1].conv, proto.Conv_Id(3))
	}

	// More continues from where the search got to, with the same query, and
	// adds to the results.
	search_start(c, {more = true})
	r, ok = tc_one(t, &tc, .Msg_Search)
	testing.expect(t, ok)
	s, _ = proto.decode_msg_search(r.body)
	testing.expect_value(t, s.before, proto.Msg_Id(70))
	testing.expect_value(t, s.query, "hello world")
	testing.expect_value(t, s.conv, proto.Conv_Id(3))
	tc_answer(&tc, r.id, .Ok, answer_body(10, 0, {hit(60, 3, "one more hello")}))
	testing.expect_value(t, len(v.search.found), 3)
	testing.expect(t, !v.search.more)

	// A new search starts from nothing, and "all" searches every conversation.
	c.convs.viewing = 4
	search_start(c, {query = "other", all = true})
	r, _ = tc_one(t, &tc, .Msg_Search)
	s, _ = proto.decode_msg_search(r.body)
	testing.expect_value(t, s.conv, proto.Conv_Id(0))
	testing.expect_value(t, s.before, proto.Msg_Id(0))
	testing.expect_value(t, len(v.search.found), 0)
	tc_answer(&tc, r.id, .Ok, answer_body(0, 0, nil))
	testing.expect_value(t, len(v.search.found), 0)
	testing.expect(t, !v.search.more && !v.search.loading)
}

@(test)
test_search_refuses_and_fails :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)
	defer search_destroy(&tc.c)
	c := &tc.c
	c.convs.viewing = 3

	// Nothing to look for, and more of a search never made, are not sent.
	search_start(c, {query = ""})
	search_start(c, {query = "   "})
	search_start(c, {more = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	Case :: struct {
		status: proto.Status,
		error:  string,
	}
	for k in ([]Case {
			{.Invalid, "Enter a search term."},
			{.Internal, "The server failed to run the search."},
			{.Denied, "The server failed to run the search."},
			{.Reset, ""},
		}) {
		search_start(c, {query = "x"})
		r, _ := tc_one(t, &tc, .Msg_Search)
		tc_answer(&tc, r.id, k.status)
		testing.expectf(t, v.search.error == k.error, "%v: %q", k.status, v.search.error)
		testing.expect(t, !v.search.loading)
	}

	// An answer that can't be read leaves the search loading.
	search_start(c, {query = "x"})
	r, _ := tc_one(t, &tc, .Msg_Search)
	tc_answer(&tc, r.id, .Ok, []u8{1, 2})
	testing.expect(t, v.search.loading)
}

@(test)
test_search_answers_out_of_date :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)
	defer search_destroy(&tc.c)
	c := &tc.c
	c.convs.viewing = 3

	search_start(c, {query = "first"})
	old, _ := tc_one(t, &tc, .Msg_Search)
	search_start(c, {query = "second"})
	newer, _ := tc_one(t, &tc, .Msg_Search)

	tc_answer(&tc, old.id, .Ok, answer_body(5, 0, {hit(9, 3, "from the first search")}))
	testing.expect_value(t, len(v.search.found), 0)
	testing.expect(t, v.search.loading)
	tc_answer(&tc, newer.id, .Ok, answer_body(5, 0, {hit(8, 3, "from the second search")}))
	testing.expect_value(t, len(v.search.found), 1)
	testing.expect_value(t, v.search.found[0].msg.text, "from the second search")
	testing.expect_value(t, v.search.query, "second")

	// An error from an old search doesn't show either.
	search_start(c, {query = "third"})
	third, _ := tc_one(t, &tc, .Msg_Search)
	search_start(c, {query = "fourth"})
	_, _ = tc_one(t, &tc, .Msg_Search)
	tc_answer(&tc, third.id, .Internal)
	testing.expect_value(t, v.search.error, "")
}

// ---- invites ----

@(test)
test_invite_create :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)

	invite_create(&tc.c, {max_uses = 5, expires = 99_000})
	r, ok := tc_one(t, &tc, .Invite_Create)
	testing.expect(t, ok)
	uses, expires, dec := proto.decode_invite_create(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, uses, u16(5))
	testing.expect_value(t, expires, proto.Unix_Ms(99_000))

	// The answer is the code, which is shown, and the list is asked for again.
	buf: [1 + proto.INVITE_CODE_SIZE]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_invite_code(&buf, "abcde23456"))
	// shown the way codes are written, whatever case the server used
	testing.expect_value(t, v.invites.made, "ABCDE23456")
	testing.expect_value(t, v.invites.made_count, 1)
	_, listed := tc_one(t, &tc, .Invite_List)
	testing.expect(t, listed)

	// A code that is malformed is not shown.
	invite_create(&tc.c, {})
	r, _ = tc_one(t, &tc, .Invite_Create)
	tc_answer(&tc, r.id, .Ok, proto.encode_invite_code(&buf, "nope"))
	testing.expect_value(t, v.invites.made, "ABCDE23456")
	testing.expect_value(t, v.invites.made_count, 1)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// Refusals.
	invite_create(&tc.c, {})
	r, _ = tc_one(t, &tc, .Invite_Create)
	tc_answer(&tc, r.id, .Too_Large)
	testing.expect_value(
		t,
		v.notice.text,
		"You've reached the maximum number of invite codes. Revoke some of them first.",
	)
	invite_create(&tc.c, {})
	r, _ = tc_one(t, &tc, .Invite_Create)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, v.notice.text, status_text(.Denied))
	testing.expect(t, !v.notice.ok)
}

@(test)
test_invite_list_and_revoke :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)

	invites_list(&tc.c)
	r, ok := tc_one(t, &tc, .Invite_List)
	testing.expect(t, ok)
	out: [1024]u8
	tc_answer(
		&tc,
		r.id,
		.Ok,
		proto.encode_invites(
			out[:],
			{
				{code = "AAAAA22222", creator = 1, created = 5, max_uses = 3, uses = 1},
				{code = "BBBBB33333", creator = 2, created = 4, revoked = true},
			},
		),
	)
	testing.expect_value(t, len(v.invites.list), 2)
	testing.expect_value(t, v.invites.count, 1)
	if len(v.invites.list) == 2 {
		testing.expect_value(t, v.invites.list[0].code, "AAAAA22222")
		testing.expect_value(t, v.invites.list[0].uses, u16(1))
		testing.expect(t, v.invites.list[1].revoked)
	}

	// A new list replaces the old one. A refusal or an unreadable one changes nothing.
	invites_list(&tc.c)
	r, _ = tc_one(t, &tc, .Invite_List)
	tc_answer(&tc, r.id, .Ok, proto.encode_invites(out[:], {{code = "CCCCC44444"}}))
	testing.expect_value(t, len(v.invites.list), 1)
	invites_list(&tc.c)
	r, _ = tc_one(t, &tc, .Invite_List)
	tc_answer(&tc, r.id, .Denied)
	invites_list(&tc.c)
	r, _ = tc_one(t, &tc, .Invite_List)
	tc_answer(&tc, r.id, .Ok, []u8{7})
	testing.expect_value(t, len(v.invites.list), 1)
	testing.expect_value(t, v.invites.count, 2)

	// Revoking asks for the list again when it worked, and says so when it didn't.
	invite_revoke(&tc.c, "CCCCC44444")
	r, ok = tc_one(t, &tc, .Invite_Revoke)
	testing.expect(t, ok)
	code, dec := proto.decode_invite_code(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, code, "CCCCC44444")
	tc_answer(&tc, r.id, .Ok)
	_, listed := tc_one(t, &tc, .Invite_List)
	testing.expect(t, listed)

	invite_revoke(&tc.c, "CCCCC44444")
	r, _ = tc_one(t, &tc, .Invite_Revoke)
	tc_answer(&tc, r.id, .Not_Found)
	testing.expect_value(t, v.notice.text, "That invite no longer exists.")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// A code too long to send is not sent.
	invite_revoke(&tc.c, "this code is far too long to be one")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_invite_of :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)

	invite_of(&tc.c, 2)
	r, ok := tc_one(t, &tc, .Invite_Of)
	testing.expect(t, ok)
	who, who_ok := proto.decode_account_id(r.body)
	testing.expect(t, who_ok)
	testing.expect_value(t, who, proto.Account_Id(2))
	buf: [proto.INVITE_OF_SIZE]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_invite_of(&buf, "DDDDD55555", 1))
	testing.expect_value(t, v.invites.of[2].code, "DDDDD55555")
	testing.expect_value(t, v.invites.of[2].creator, proto.Account_Id(1))

	// An account that registered without one has none, which is recorded so that
	// it isn't asked about again; asking again replaces the earlier answer.
	invite_of(&tc.c, 3)
	r, _ = tc_one(t, &tc, .Invite_Of)
	tc_answer(&tc, r.id, .Not_Found)
	entry, has := v.invites.of[3]
	testing.expect(t, has)
	testing.expect_value(t, entry.code, "")
	invite_of(&tc.c, 2)
	r, _ = tc_one(t, &tc, .Invite_Of)
	tc_answer(&tc, r.id, .Ok, proto.encode_invite_of(&buf, "EEEEE66666", 2))
	testing.expect_value(t, v.invites.of[2].code, "EEEEE66666")
	testing.expect_value(t, len(v.invites.of), 2)

	// Other failures and unreadable answers record nothing.
	invite_of(&tc.c, 4)
	r, _ = tc_one(t, &tc, .Invite_Of)
	tc_answer(&tc, r.id, .Denied)
	invite_of(&tc.c, 4)
	r, _ = tc_one(t, &tc, .Invite_Of)
	tc_answer(&tc, r.id, .Ok, []u8{9})
	testing.expect_value(t, len(v.invites.of), 2)
}

// ---- activity ----

@(test)
test_activity_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_service(&tc)
	defer tc_close(&tc)

	activity_set(&tc.c, .Busy, 0)
	r, ok := tc_one(t, &tc, .Activity_Set)
	testing.expect(t, ok)
	testing.expect_value(t, len(r.body), 1)
	a, dec := proto.decode_activity(r.body)
	testing.expect(t, dec)
	testing.expect_value(t, a, proto.Activity.Busy)
	testing.expect_value(t, proto.decode_activity_at(r.body), proto.Unix_Ms(0))

	// Copied from another server, it says when it was chosen.
	activity_set(&tc.c, .Away, 123_456)
	r, _ = tc_one(t, &tc, .Activity_Set)
	testing.expect_value(t, proto.decode_activity_at(r.body), proto.Unix_Ms(123_456))

	count := v.notice.count
	tc_answer(&tc, r.id, .Ok)
	testing.expect_value(t, v.notice.count, count)
	activity_set(&tc.c, .Away, 0)
	r, _ = tc_one(t, &tc, .Activity_Set)
	tc_answer(&tc, r.id, .Internal)
	testing.expect_value(t, v.notice.text, "The server failed to change your activity (Internal).")
}

@(test)
test_idle_set :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_service(&tc)
	defer tc_close(&tc)
	a := &tc.c.auth

	idle_set(&tc.c, true, false)
	r, ok := tc_one(t, &tc, .Idle_Set)
	testing.expect(t, ok)
	idle, hidden, dec := proto.decode_idle(r.body)
	testing.expect(t, dec && idle && !hidden)
	idle_set(&tc.c, false, true)
	r, _ = tc_one(t, &tc, .Idle_Set)
	idle, hidden, _ = proto.decode_idle(r.body)
	testing.expect(t, !idle && hidden)

	// Before the login is finished it is kept, and sent when the login completes.
	a.state = .Working
	idle_set(&tc.c, true, true)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect(t, a.idle && a.hidden)
	buf: [proto.SELF_SIZE]u8
	tc_event(&tc, .Self, proto.encode_self(&buf, 1, {}, {}))
	r, ok = tc_one(t, &tc, .Idle_Set)
	testing.expect(t, ok)
	idle, hidden, _ = proto.decode_idle(r.body)
	testing.expect(t, idle && hidden)
}

@(test)
test_quiet :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_service(&tc)
	defer tc_close(&tc)
	buf: [proto.SELF_SIZE]u8
	testing.expect(t, !quiet(&tc.c))
	tc.c.auth.state = .Working
	tc_event(&tc, .Self, proto.encode_self(&buf, 1, {}, {}, .Busy))
	testing.expect(t, quiet(&tc.c), "being busy is not quiet")
	tc_event(&tc, .Self, proto.encode_self(&buf, 1, {}, {}, .Away))
	testing.expect(t, !quiet(&tc.c), "being away is quiet")
}
