package server

import "core:fmt"
import "core:testing"

import "common:proto"

// Tests of the rights in channels (proto.Conv_Right): default channels, text-only
// channels and what each role may do in a channel, using the Test_Server from
// harness_test.odin.

@(private = "file")
rights_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	entries: ..proto.Role_Rights,
) -> proto.Status {
	buf: [proto.CONV_RIGHTS_SET_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		ts,
		u,
		.Conv_Rights_Set,
		proto.encode_conv_rights_set(buf[:], conv, entries),
	)
	return status
}

@(private = "file")
rights_get :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	buf: []proto.Role_Rights,
) -> (
	proto.Status,
	[]proto.Role_Rights,
) {
	id_buf: [4]u8
	status, body := ts_ask(t, ts, u, .Conv_Rights_Get, proto.encode_conv_id(&id_buf, conv))
	entries, _ := proto.decode_rights_map(body, buf)
	return status, entries
}

@(private = "file")
channel_create :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	name: string,
	private := false,
	flags := proto.Conv_Flags{},
) -> (
	proto.Status,
	proto.Conv_Id,
) {
	buf: [proto.CONV_CREATE_MAX_SIZE]u8
	status, body := ts_ask(
		t,
		ts,
		u,
		.Conv_Create,
		proto.encode_conv_create(buf[:], name, "", private, flags),
	)
	id, _ := proto.decode_conv_id(body)
	return status, id
}

// told_rights returns the rights in the last Conv_Changed about `conv` that a
// connection was sent since its events were last read, and whether there was
// one.
@(private = "file")
told_rights :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> (
	rights: proto.Conv_Rights,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op != .Conv_Changed {
			continue
		}
		if c, ok := proto.decode_conv(e.body); ok && c.id == conv {
			rights, told = c.rights, true
		}
	}
	return
}

@(test)
test_conv_rights_map :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	home := s.convs.home.id

	// Everyone may do everything in a new channel, and is told so.
	status, news := channel_create(t, &ts, owner, "News")
	testing.expect_value(t, status, proto.Status.Ok)
	rights, told := told_rights(t, &ts, owner, news)
	testing.expect(t, told)
	testing.expect_value(t, rights, proto.CONV_RIGHTS_ALL)
	buf: [proto.MAX_ROLES]proto.Role_Rights
	entries: []proto.Role_Rights
	status, entries = rights_get(t, &ts, owner, news, buf[:])
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {
		testing.expect_value(
			t,
			entries[0],
			proto.Role_Rights{proto.EVERYONE_ROLE, proto.CONV_RIGHTS_ALL},
		)
	}

	// Reading and changing a map is for Manage_Channels.
	status, _ = rights_get(t, &ts, alice, news, buf[:])
	testing.expect_value(t, status, proto.Status.Denied)
	status = rights_set(t, &ts, alice, news, {proto.EVERYONE_ROLE, {}})
	testing.expect_value(t, status, proto.Status.Denied)
	status = rights_set(t, &ts, owner, 999, {proto.EVERYONE_ROLE, {}})
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Every role must exist and appear once.
	status = rights_set(t, &ts, owner, news, {77, {.See}})
	testing.expect_value(t, status, proto.Status.Invalid)
	status = rights_set(
		t,
		&ts,
		owner,
		news,
		{proto.EVERYONE_ROLE, {.See}},
		{proto.EVERYONE_ROLE, {.See}},
	)
	testing.expect_value(t, status, proto.Status.Invalid)

	// Everyone keeps seeing the home channel.
	status = rights_set(t, &ts, owner, home, {proto.EVERYONE_ROLE, {.Write}})
	testing.expect_value(t, status, proto.Status.Invalid)
	ts_events(t, &ts, alice)
	status = rights_set(t, &ts, owner, home, {proto.EVERYONE_ROLE, {.See, .React}})
	testing.expect_value(t, status, proto.Status.Ok)
	rights, told = told_rights(t, &ts, alice, home)
	testing.expect(t, told, "alice wasn't told about the new rights in the home channel")
	testing.expect_value(t, rights, proto.Conv_Rights{.See, .React})
	// The owner may do everything regardless.
	rights, told = told_rights(t, &ts, owner, home)
	testing.expect(t, told)
	testing.expect_value(t, rights, proto.CONV_RIGHTS_ALL)

	// A role adds its rights to everyone's, and the rules between rights
	// apply to the sum: Edit without Write is nothing.
	writers: proto.Role_Id
	{
		role_buf: [proto.ROLE_MAX_SIZE]u8
		body: []u8
		status, body = ts_ask(
			t,
			&ts,
			owner,
			.Role_Set,
			proto.encode_role(role_buf[:], {name = "writers"}),
		)
		raw, _ := proto.decode_account_id(body)
		writers = proto.Role_Id(raw)
	}
	status = rights_set(
		t,
		&ts,
		owner,
		home,
		{proto.EVERYONE_ROLE, {.See, .Edit}},
		{writers, {.Write}},
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, conv_rights(s.convs.home, alice_acc), proto.Conv_Rights{.See})
	testing.expect(t, account_roles_set(&s.accounts, alice_acc, {writers}))
	testing.expect_value(
		t,
		conv_rights(s.convs.home, alice_acc),
		proto.Conv_Rights{.See, .Write, .Edit},
	)

	// The map is in the database, and a deleted role leaves it.
	status, entries = rights_get(t, &ts, owner, home, buf[:])
	testing.expect_value(t, len(entries), 2)
	id_buf: [4]u8
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Role_Delete,
		proto.encode_account_id(&id_buf, proto.Account_Id(writers)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	status, entries = rights_get(t, &ts, owner, home, buf[:])
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, conv_rights(s.convs.home, alice_acc), proto.Conv_Rights{.See})
	q := db_stmt(&s.db, .Conv_Rights_All)
	rows := 0
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		testing.expect(t, proto.Role_Id(db_col_int(q, 1)) == proto.EVERYONE_ROLE)
		rows += 1
	}
	// One for each channel.
	testing.expect_value(t, rows, channel_count(&s.convs))

	// In a DM both accounts may do everything but talk.
	dm := dm_add(&s.convs, alice_acc.id, owner.account.id, alice_acc.id)
	testing.expect(t, dm != nil)
	testing.expect_value(t, conv_rights(dm, alice_acc), proto.CONV_RIGHTS_ALL - {.Voice})
}

// update_flags sets a channel's Default and Text_Only flags with Conv_Update.
@(private = "file")
update_flags :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	flags: proto.Conv_Flags,
) -> proto.Status {
	buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		ts,
		u,
		.Conv_Update,
		proto.encode_conv_update(
			buf[:],
			{conv = conv, mask = proto.CONV_UPDATE_FLAGS, flags = flags},
		),
	)
	return status
}

@(private = "file")
subscribe :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Conv_Subscribe, proto.encode_conv_subscribe(&buf, conv, on))
	return status
}

@(private = "file")
voice_join_room :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> proto.Status {
	buf: [4]u8
	status, _ := ts_ask(t, ts, u, .Voice_Join, proto.encode_room(&buf, proto.Room(conv)))
	return status
}

@(test)
test_default_channels :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")

	// A default channel can't be private, and the home channel is more than
	// default already.
	status, _ := channel_create(t, &ts, owner, "Secret", true, {.Default})
	testing.expect_value(t, status, proto.Status.Invalid)
	status = update_flags(t, &ts, owner, s.convs.home.id, {.Default})
	testing.expect_value(t, status, proto.Status.Invalid)

	news, plain, staff, hidden: proto.Conv_Id
	status, news = channel_create(t, &ts, owner, "News", false, {.Default})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, .Default in conv_by_id(&s.convs, news).flags)
	_, plain = channel_create(t, &ts, owner, "Plain")
	_, staff = channel_create(t, &ts, owner, "Staff", true)
	_, hidden = channel_create(t, &ts, owner, "Hidden", false, {.Default})
	// Only managers can see Hidden, so new accounts aren't put in it.
	status = rights_set(t, &ts, owner, hidden, {proto.EVERYONE_ROLE, {}})
	testing.expect_value(t, status, proto.Status.Ok)
	// Turning Default on later doesn't add anyone who is already there.
	status = update_flags(t, &ts, owner, plain, {.Default})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, !conv_is_member(conv_by_id(&s.convs, plain), alice_acc.id))
	// Nor can a private channel become default.
	status = update_flags(t, &ts, owner, staff, {.Default})
	testing.expect_value(t, status, proto.Status.Invalid)

	// A new account starts in the home channel and the default ones it can see.
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		owner,
		.Account_Create,
		proto.encode_account_create(buf[:], "bob", "first password", "Bob"),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	bob_id, _ := proto.decode_account_id(body)
	testing.expect(t, conv_is_member(s.convs.home, bob_id))
	testing.expect(t, conv_is_member(conv_by_id(&s.convs, news), bob_id))
	testing.expect(t, conv_is_member(conv_by_id(&s.convs, plain), bob_id))
	testing.expect(t, !conv_is_member(conv_by_id(&s.convs, staff), bob_id))
	testing.expect(t, !conv_is_member(conv_by_id(&s.convs, hidden), bob_id))

	// One may leave a default channel, unlike the home channel.
	testing.expect_value(t, subscribe(t, &ts, alice, news, true), proto.Status.Ok)
	testing.expect_value(t, subscribe(t, &ts, alice, news, false), proto.Status.Ok)
	testing.expect(t, !conv_is_member(conv_by_id(&s.convs, news), alice_acc.id))

	// Changing the flags sets both of them.
	status = update_flags(t, &ts, owner, news, {.Text_Only})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, conv_by_id(&s.convs, news).flags, proto.Conv_Flags{.Text_Only})
}

@(test)
test_text_only_channels :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")

	status, notes := channel_create(t, &ts, owner, "Notes", false, {.Text_Only})
	testing.expect_value(t, status, proto.Status.Ok)
	rights, _ := told_rights(t, &ts, owner, notes)
	testing.expect_value(t, rights, proto.CONV_RIGHTS_ALL - {.Voice})
	testing.expect_value(t, voice_join_room(t, &ts, owner, notes), proto.Status.Denied)

	// Turning it on empties the room, and turning it off opens it again.
	talk: proto.Conv_Id
	_, talk = channel_create(t, &ts, owner, "Talk")
	testing.expect_value(t, voice_join_room(t, &ts, alice, talk), proto.Status.Ok)
	ts_events(t, &ts, alice)
	testing.expect_value(t, update_flags(t, &ts, owner, talk, {.Text_Only}), proto.Status.Ok)
	testing.expect_value(t, alice.room, proto.Room(0))
	e, moved := has_event(ts_events(t, &ts, alice), .Voice_Moved)
	testing.expect(t, moved, "alice wasn't moved out of the room")
	room, _ := proto.decode_room(e.body)
	testing.expect_value(t, room, proto.Room(0))
	testing.expect_value(t, update_flags(t, &ts, owner, talk, {}), proto.Status.Ok)
	testing.expect_value(t, voice_join_room(t, &ts, alice, talk), proto.Status.Ok)
}

// browsed says whether the first page of Conv_Browse has a channel.
@(private = "file")
browsed :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, conv: proto.Conv_Id) -> bool {
	_, body := ts_ask(t, ts, u, .Conv_Browse, nil)
	list_buf: [16]proto.Conv
	_, list, _ := proto.decode_browse_page(body, list_buf[:])
	for c in list {
		if c.id == conv {
			return true
		}
	}
	return false
}

@(test)
test_conv_rights_enforced :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	everyone := proto.EVERYONE_ROLE

	writers: proto.Role_Id
	{
		role_buf: [proto.ROLE_MAX_SIZE]u8
		_, body := ts_ask(
			t,
			&ts,
			owner,
			.Role_Set,
			proto.encode_role(role_buf[:], {name = "writers"}),
		)
		raw, _ := proto.decode_account_id(body)
		writers = proto.Role_Id(raw)
	}
	_, news := channel_create(t, &ts, owner, "News")
	testing.expect_value(t, subscribe(t, &ts, alice, news, true), proto.Status.Ok)
	testing.expect_value(t, subscribe(t, &ts, bob, news, true), proto.Status.Ok)
	_, from_owner := post(t, &ts, owner, news, "welcome", 1)
	status, from_alice := post(t, &ts, alice, news, "hi", 2)
	testing.expect_value(t, status, proto.Status.Ok)

	// Everyone may read and react; writing, editing and deleting is for writers.
	ts_events(t, &ts, alice)
	status = rights_set(
		t,
		&ts,
		owner,
		news,
		{everyone, {.See, .React}},
		{writers, {.Write, .Edit, .Delete}},
	)
	testing.expect_value(t, status, proto.Status.Ok)
	rights, told := told_rights(t, &ts, alice, news)
	testing.expect(t, told, "alice wasn't told about the new rights")
	testing.expect_value(t, rights, proto.Conv_Rights{.See, .React})
	status, _ = post(t, &ts, alice, news, "again", 3)
	testing.expect_value(t, status, proto.Status.Denied)
	testing.expect_value(t, edit_as(t, &ts, alice, from_alice, "changed"), proto.Status.Denied)
	testing.expect_value(t, delete_as(t, &ts, alice, from_alice), proto.Status.Denied)
	testing.expect_value(t, react_as(t, &ts, alice, from_owner, "👍", true), proto.Status.Ok)
	history_status, _ := ts_ask(t, &ts, alice, .Msg_History, history_body(news))
	testing.expect_value(t, history_status, proto.Status.Ok)

	// A writer may, and is told so as soon as the role is given.
	testing.expect_value(t, roles_give_one(t, &ts, owner, alice_acc.id, writers), proto.Status.Ok)
	rights, told = told_rights(t, &ts, alice, news)
	testing.expect(t, told, "alice wasn't told about the role's rights")
	testing.expect_value(t, rights, proto.Conv_Rights{.See, .React, .Write, .Edit, .Delete})
	status, _ = post(t, &ts, alice, news, "again", 4)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, edit_as(t, &ts, alice, from_alice, "changed"), proto.Status.Ok)
	testing.expect_value(t, delete_as(t, &ts, alice, from_alice), proto.Status.Ok)

	// Edit and Delete need Write: a role that only gives those doesn't do.
	status = rights_set(t, &ts, owner, news, {everyone, {.See, .Edit, .Delete}})
	testing.expect_value(t, status, proto.Status.Ok)
	_, bob_msg := post(t, &ts, bob, news, "bob's", 6) // refused: no Write
	testing.expect_value(t, bob_msg, proto.Msg_Id(0))
	status = rights_set(t, &ts, owner, news, {everyone, {.See, .Write}})
	testing.expect_value(t, status, proto.Status.Ok)
	_, bob_msg = post(t, &ts, bob, news, "bob's", 7)
	testing.expect_value(t, edit_as(t, &ts, bob, bob_msg, "changed"), proto.Status.Denied)
	testing.expect_value(t, delete_as(t, &ts, bob, bob_msg), proto.Status.Denied)
	testing.expect_value(t, react_as(t, &ts, bob, from_owner, "👍", true), proto.Status.Denied)
	// Manage_Messages still deletes anyone's messages.
	testing.expect_value(t, delete_as(t, &ts, owner, bob_msg), proto.Status.Ok)

	// Losing See: bob stays a member but is told it is gone, can't read it,
	// find it or join it, and isn't sent what happens there.
	ts_events(t, &ts, bob)
	status = rights_set(t, &ts, owner, news, {everyone, {}}, {writers, proto.CONV_RIGHTS_ALL})
	testing.expect_value(t, status, proto.Status.Ok)
	e, removed := has_event(ts_events(t, &ts, bob), .Conv_Removed)
	testing.expect(t, removed, "bob wasn't told the channel is gone")
	gone, _ := proto.decode_conv_id(e.body)
	testing.expect_value(t, gone, news)
	testing.expect(t, conv_is_member(conv_by_id(&s.convs, news), bob_acc.id))
	history_status, _ = ts_ask(t, &ts, bob, .Msg_History, history_body(news))
	testing.expect_value(t, history_status, proto.Status.Not_Found)
	testing.expect(t, !browsed(t, &ts, bob, news))
	testing.expect_value(t, subscribe(t, &ts, bob, news, true), proto.Status.Not_Found)
	testing.expect_value(t, voice_join_room(t, &ts, bob, news), proto.Status.Not_Found)
	post(t, &ts, alice, news, fmt.tprintf("hello <@%d> and <@everyone>", bob_acc.id), 8)
	_, delivered := has_event(ts_events(t, &ts, bob), .Msg_New)
	testing.expect(t, !delivered, "bob was sent a message from a channel bob can't see")
	// Nobody else can add bob to it.
	member_buf: [proto.CONV_MEMBER_SET_SIZE]u8
	_, staff := channel_create(t, &ts, owner, "Staff", true)
	testing.expect_value(
		t,
		rights_set(t, &ts, owner, staff, {writers, proto.CONV_RIGHTS_ALL}),
		proto.Status.Ok,
	)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&member_buf, staff, bob_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&member_buf, staff, alice_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)

	// Getting See back brings the channel back, read state and all.
	status = rights_set(t, &ts, owner, news, {everyone, {.See, .Voice}})
	testing.expect_value(t, status, proto.Status.Ok)
	rights, told = told_rights(t, &ts, bob, news)
	testing.expect(t, told, "bob wasn't told the channel is back")
	testing.expect_value(t, rights, proto.Conv_Rights{.See, .Voice})

	// Voice: whoever loses it leaves the room and can't join again.
	testing.expect_value(t, voice_join_room(t, &ts, bob, news), proto.Status.Ok)
	status = rights_set(t, &ts, owner, news, {everyone, {.See}})
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, bob.room, proto.Room(0))
	testing.expect_value(t, voice_join_room(t, &ts, bob, news), proto.Status.Denied)
	// Writers have every right there, Voice included.
	testing.expect_value(t, voice_join_room(t, &ts, alice, news), proto.Status.Denied)
	status = rights_set(t, &ts, owner, news, {everyone, {.See}}, {writers, {.Voice}})
	testing.expect_value(t, voice_join_room(t, &ts, alice, news), proto.Status.Ok)

	// Taking the role away takes its rights with it, the room included.
	testing.expect_value(t, roles_give_one(t, &ts, owner, alice_acc.id), proto.Status.Ok)
	testing.expect_value(t, alice.room, proto.Room(0))
}

@(private = "file")
roles_give_one :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	roles: ..proto.Role_Id,
) -> proto.Status {
	buf: [proto.ACCOUNT_ROLES_MAX_SIZE]u8
	status, _ := ts_ask(
		t,
		ts,
		u,
		.Account_Roles_Set,
		proto.encode_account_roles(buf[:], account, roles),
	)
	return status
}

@(test)
test_conv_rights_attach :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	everyone := proto.EVERYONE_ROLE
	_, news := channel_create(t, &ts, owner, "News")
	testing.expect_value(t, subscribe(t, &ts, alice, news, true), proto.Status.Ok)

	// A message with files, of an upload that doesn't exist: the rights are
	// checked before that.
	post_file :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		conv: proto.Conv_Id,
	) -> proto.Status {
		p := proto.Msg_Post {
			conv             = conv,
			nonce            = 99,
			kind             = .Text,
			text             = "see attached",
			attachment_count = 1,
		}
		p.uploads[0] = 12345
		buf: [proto.MSG_POST_MAX_SIZE]u8
		status, _ := ts_ask(t, ts, u, .Msg_Post, proto.encode_msg_post(buf[:], p))
		return status
	}

	// Everyone may attach in a new channel.
	testing.expect(t, post_file(t, &ts, alice, news) != .Denied)
	// Writing without attaching.
	status := rights_set(t, &ts, owner, news, {everyone, {.See, .Write}})
	testing.expect_value(t, status, proto.Status.Ok)
	rights, _ := told_rights(t, &ts, alice, news)
	testing.expect_value(t, rights, proto.Conv_Rights{.See, .Write})
	testing.expect_value(t, post_file(t, &ts, alice, news), proto.Status.Denied)
	status, _ = post(t, &ts, alice, news, "just text", 100)
	testing.expect_value(t, status, proto.Status.Ok)
	// Attach without Write is nothing.
	status = rights_set(t, &ts, owner, news, {everyone, {.See, .Attach}})
	testing.expect_value(t, status, proto.Status.Ok)
	rights, _ = told_rights(t, &ts, alice, news)
	testing.expect_value(t, rights, proto.Conv_Rights{.See})
	testing.expect_value(t, post_file(t, &ts, alice, news), proto.Status.Denied)
	// Both.
	status = rights_set(t, &ts, owner, news, {everyone, {.See, .Write, .Attach}})
	testing.expect(t, post_file(t, &ts, alice, news) != .Denied)
}
