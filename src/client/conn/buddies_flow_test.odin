#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of buddies, DMs and groups (buddies.odin): who a name refers to, how
// the other end of a DM or group is worked out, and what each command asks of
// the server.

@(private = "file")
open_people :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc_account(tc, 1, "bob", "Bob")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "carol", "Carol")
	tc_account(tc, 4, "dave", "Dave")
	return tc_view(tc)
}

@(private = "file")
tc_dm :: proc(tc: ^Test_Conn, id: proto.Conv_Id, a, b: proto.Account_Id) {
	info := Conv_Info {
		kind          = .DM,
		account_count = 2,
	}
	info.accounts[0], info.accounts[1] = a, b
	tc.c.convs.convs[id] = info
}

@(private = "file")
tc_group :: proc(tc: ^Test_Conn, id: proto.Conv_Id, members: ..proto.Account_Id) {
	info := Conv_Info {
		kind          = .Group,
		account_count = len(members),
	}
	for m, i in members {
		info.accounts[i] = m
	}
	tc.c.convs.convs[id] = info
}

@(test)
test_names_refer_to_accounts :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// A username first, then a display name.
	testing.expect_value(t, account_named(c, "alice"), proto.Account_Id(2))
	testing.expect_value(t, account_named(c, "Carol"), proto.Account_Id(3))
	testing.expect_value(t, account_named(c, "nobody"), proto.Account_Id(0))
	testing.expect_value(t, account_named(c, ""), proto.Account_Id(0))

	// A display name that is another account's username goes to the username.
	tc_account(&tc, 5, "erin", "alice")
	testing.expect_value(t, account_named(c, "alice"), proto.Account_Id(2))
	testing.expect_value(t, account_named(c, "erin"), proto.Account_Id(5))
}

@(test)
test_dm_and_group_members :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	tc_dm(&tc, 10, 1, 2)
	tc_dm(&tc, 11, 4, 1) // we are not first
	tc_dm(&tc, 12, 1, 1) // notes: a DM with ourselves
	tc_group(&tc, 13, 1, 2, 3)
	tc_conv(&tc, 14, "Lobby")

	// The other end of a DM is the one that isn't us.
	testing.expect_value(t, dm_other(c, c.convs.convs[10]), proto.Account_Id(2))
	testing.expect_value(t, dm_other(c, c.convs.convs[11]), proto.Account_Id(4))
	testing.expect_value(t, dm_other(c, c.convs.convs[12]), proto.Account_Id(1))
	testing.expect_value(t, dm_other(c, c.convs.convs[13]), proto.Account_Id(0)) // not a DM
	testing.expect_value(t, dm_other(c, c.convs.convs[14]), proto.Account_Id(0))
	testing.expect_value(t, dm_other(c, Conv_Info{kind = .DM}), proto.Account_Id(0))
	// A count out of range is clamped, not trusted.
	bad := c.convs.convs[10]
	bad.account_count = 1000
	testing.expect_value(t, dm_other(c, bad), proto.Account_Id(2))
	bad.account_count = -4
	testing.expect_value(t, dm_other(c, bad), proto.Account_Id(0))

	testing.expect_value(t, dm_with(c, 2), proto.Conv_Id(10))
	testing.expect_value(t, dm_with(c, 4), proto.Conv_Id(11))
	testing.expect_value(t, dm_with(c, 1), proto.Conv_Id(12))
	testing.expect_value(t, dm_with(c, 3), proto.Conv_Id(0)) // only in a group

	others := group_others(c, c.convs.convs[13])
	testing.expect_value(t, len(others), 2)
	if len(others) == 2 {
		testing.expect_value(t, others[0], proto.Account_Id(2))
		testing.expect_value(t, others[1], proto.Account_Id(3))
	}
	testing.expect_value(t, len(group_others(c, c.convs.convs[10])), 0)
	testing.expect_value(t, group_name(c, c.convs.convs[13]), "Alice, Carol")

	// What a conversation is called in the lists.
	testing.expect_value(t, room_name(c, 10), "DMs with Alice")
	testing.expect_value(t, room_name(c, 13), "the group with Alice, Carol")
	testing.expect_value(t, room_name(c, 14), "Lobby")
	testing.expect_value(t, room_name(c, 99), "channel #99")
}

@(test)
test_buddy_events :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_people(&tc)
	defer tc_close(&tc)
	defer buddies_destroy(&tc.c)
	c := &tc.c
	buf: [proto.BUDDY_SET_SIZE]u8

	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 2, true))
	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 3, true))
	testing.expect_value(t, len(c.buddies.buddies), 2)
	testing.expect_value(t, len(v.buddies), 2)

	// Hearing the same thing twice changes nothing, in either direction.
	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 2, true))
	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 4, false))
	testing.expect_value(t, len(c.buddies.buddies), 2)

	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 2, false))
	testing.expect_value(t, len(c.buddies.buddies), 1)
	testing.expect_value(t, c.buddies.buddies[0], proto.Account_Id(3))
	testing.expect_value(t, len(v.buddies), 1)

	// A body that can't be read, or names nobody, is ignored.
	tc_event(&tc, .Buddy_Changed, []u8{1, 2})
	tc_event(&tc, .Buddy_Changed, proto.encode_buddy(&buf, 0, true))
	testing.expect_value(t, len(c.buddies.buddies), 1)

	// A new sync starts from none, and so does a logout.
	tc_event(&tc, .Sync_Begin)
	testing.expect_value(t, len(c.buddies.buddies), 0)
	testing.expect_value(t, len(v.buddies), 0)
}

@(test)
test_buddy_command :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	buddy_command(c, {name = "alice", on = true})
	r, ok := tc_one(t, &tc, .Buddy_Set)
	testing.expect(t, ok)
	account, on, dec := proto.decode_buddy(r.body)
	testing.expect(t, dec && on)
	testing.expect_value(t, account, proto.Account_Id(2))
	buddy_command(c, {account = 3, on = false})
	r, _ = tc_one(t, &tc, .Buddy_Set)
	account, on, _ = proto.decode_buddy(r.body)
	testing.expect_value(t, account, proto.Account_Id(3))
	testing.expect(t, !on)

	// Not ourselves, and not nobody.
	buddy_command(c, {name = "bob", on = true})
	buddy_command(c, {account = 1, on = true})
	buddy_command(c, {name = "nobody", on = true})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_group_command :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// By names: commas, blanks, a name twice.
	group_command(c, {names = " alice, Carol ,,alice"})
	r, ok := tc_one(t, &tc, .Group_Open)
	testing.expect(t, ok)
	buf: [proto.MAX_GROUP_MEMBERS - 1]proto.Account_Id
	others, dec := proto.decode_group_open(r.body, &buf)
	testing.expect(t, dec)
	testing.expect_value(t, len(others), 2)

	// By accounts.
	cmd := Group_Command {
		accounts = {0 = 2, 1 = 3, 2 = 4},
		count    = 3,
	}
	group_command(c, cmd)
	r, ok = tc_one(t, &tc, .Group_Open)
	testing.expect(t, ok)
	others, dec = proto.decode_group_open(r.body, &buf)
	testing.expect(t, dec && len(others) == 3)

	// One other is a DM, not a group, and nobody is neither. A name nobody
	// has, or ourselves, stops the whole thing.
	group_command(c, {names = "alice"})
	group_command(c, {names = "alice, alice"})
	group_command(c, {names = ""})
	group_command(c, {names = "alice, nobody, carol"})
	group_command(c, {names = "alice, bob, carol"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	// Too many.
	group_command(c, {names = "alice, carol, dave, a1, a2, a3, a4, a5"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_group_opened :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	c.view = nil // headless
	group_command(c, {names = "alice, carol"})
	r, _ := tc_one(t, &tc, .Group_Open)
	// The server tells us about the group before it answers; headless, it is then looked at.
	tc_group(&tc, 30, 1, 2, 3)
	buf: [4]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_conv_id(&buf, 30))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(30))

	// With a View, the UI decides what is looked at.
	c.convs.viewing = 0
	_ = tc_view(&tc)
	_ = tc_sent(t, &tc) // the history of the group that was looked at
	group_command(c, {names = "alice, carol"})
	r, _ = tc_one(t, &tc, .Group_Open)
	tc_answer(&tc, r.id, .Ok, proto.encode_conv_id(&buf, 30))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
	c.view = nil

	// A group that failed to open, or one we weren't told about, is not viewed.
	for status in ([]proto.Status{.Denied, .Not_Found, .Internal, .Reset}) {
		group_command(c, {names = "alice, carol"})
		r, _ = tc_one(t, &tc, .Group_Open)
		tc_answer(&tc, r.id, status, proto.encode_conv_id(&buf, 30))
		testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
	}
	group_command(c, {names = "alice, carol"})
	r, _ = tc_one(t, &tc, .Group_Open)
	tc_answer(&tc, r.id, .Ok, proto.encode_conv_id(&buf, 777))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
}

@(test)
test_notes :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// No notes yet: the server is asked to open the DM with ourselves.
	notes_command(c)
	r, ok := tc_one(t, &tc, .DM_Open)
	testing.expect(t, ok)
	who, who_ok := proto.decode_account_id(r.body)
	testing.expect(t, who_ok)
	testing.expect_value(t, who, proto.Account_Id(1))
	tc_dm(&tc, 40, 1, 1)
	buf: [4]u8
	tc_answer(&tc, r.id, .Ok, proto.encode_conv_id(&buf, 40))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(40))

	// With them, they are just looked at: nothing is opened.
	_ = tc_sent(t, &tc)
	c.convs.viewing = 0
	notes_command(c)
	for req in tc_sent(t, &tc) {
		testing.expect(t, req.op != .DM_Open, "the notes were opened again")
	}
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(40))

	// A refusal leaves things as they are.
	delete_key(&c.convs.convs, 40)
	c.convs.viewing = 0
	notes_command(c)
	r, _ = tc_one(t, &tc, .DM_Open)
	tc_answer(&tc, r.id, .Denied)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
}

@(test)
test_dm_command :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// An existing DM is looked at.
	tc_dm(&tc, 10, 1, 2)
	dm_command(c, {name = "alice"})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(10))
	testing.expect_value(t, len(c.msgs.outbox), 0)

	// With text, it is posted to that DM first.
	c.convs.viewing = 0
	dm_command(c, {name = "alice", text = "hello there"})
	testing.expect_value(t, len(c.msgs.outbox), 1)
	testing.expect_value(t, c.msgs.outbox[0].conv, proto.Conv_Id(10))
	testing.expect_value(t, c.msgs.outbox[0].text, "hello there")
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(10))

	// With no DM yet, the text waits for one to be opened; nothing is looked at.
	c.convs.viewing = 0
	dm_command(c, {name = "dave", text = "first!"})
	testing.expect_value(t, len(c.msgs.outbox), 2)
	testing.expect_value(t, c.msgs.outbox[1].state, Post_State.Open)
	testing.expect_value(t, c.msgs.outbox[1].dm_to, proto.Account_Id(4))
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
	dm_command(c, {name = "carol"})
	testing.expect_value(t, len(c.msgs.outbox), 2)

	// Ourselves are allowed here, but nobody else who isn't there.
	tc_dm(&tc, 12, 1, 1)
	dm_command(c, {account = 1})
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(12))
	c.convs.viewing = 0
	dm_command(c, {name = "nobody", text = "hi"})
	testing.expect_value(t, len(c.msgs.outbox), 2)
	testing.expect_value(t, c.convs.viewing, proto.Conv_Id(0))
}

@(test)
test_last_seen_command :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_people(&tc)
	defer tc_close(&tc)
	c := &tc.c

	last_seen_command(c, {name = "alice"})
	r, ok := tc_one(t, &tc, .Last_Seen)
	testing.expect(t, ok)
	abuf: [8]proto.Account_Id
	asked, dec := proto.decode_last_seen_ask(r.body, abuf[:])
	testing.expect(t, dec)
	testing.expect_value(t, len(asked), 1)
	if len(asked) == 1 {
		testing.expect_value(t, asked[0], proto.Account_Id(2))
	}

	out: [256]u8
	body := proto.encode_last_seen_answer(
		out[:],
		{{account = 2, time = 123456}, {account = 3, time = proto.LAST_SEEN_HIDDEN}, {account = 4, time = 0}},
	)
	tc_answer(&tc, r.id, .Ok, body)
	testing.expect_value(t, v.last_seen[2], proto.Unix_Ms(123456))
	testing.expect_value(t, v.last_seen[3], proto.LAST_SEEN_HIDDEN)
	testing.expect_value(t, v.last_seen[4], proto.Unix_Ms(0))

	// Several at once; unknown names and an empty request send nothing.
	cmd := Last_Seen_Command {
		accounts = {0 = 2, 1 = 3},
		count    = 2,
	}
	last_seen_command(c, cmd)
	r, _ = tc_one(t, &tc, .Last_Seen)
	asked, _ = proto.decode_last_seen_ask(r.body, abuf[:])
	testing.expect_value(t, len(asked), 2)
	last_seen_command(c, {name = "nobody"})
	last_seen_command(c, {})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// A refusal or unreadable answer changes nothing.
	last_seen_command(c, {name = "alice"})
	r, _ = tc_one(t, &tc, .Last_Seen)
	tc_answer(&tc, r.id, .Denied)
	last_seen_command(c, {name = "alice"})
	r, _ = tc_one(t, &tc, .Last_Seen)
	tc_answer(&tc, r.id, .Ok, []u8{9})
	testing.expect_value(t, len(v.last_seen), 3)
}
