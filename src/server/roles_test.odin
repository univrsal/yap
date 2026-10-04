package server

import "core:os"
import "core:testing"

import "common:proto"

// Tests of roles, managing channels and private channels, on the
// Test_Server of auth_test.odin.

@(private = "file")
role_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	r: proto.Role,
) -> (
	proto.Status,
	proto.Role_Id,
) {
	buf: [proto.ROLE_MAX_SIZE]u8
	status, body := ts_ask(t, ts, u, .Role_Set, proto.encode_role(buf[:], r))
	id, _ := proto.decode_account_id(body)
	return status, proto.Role_Id(id)
}

@(private = "file")
roles_give :: proc(
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

@(private = "file")
disable :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.ACCOUNT_DISABLE_SIZE]u8
	status, _ := ts_ask(
		t,
		ts,
		u,
		.Account_Disable,
		proto.encode_account_disable(&buf, account, on),
	)
	return status
}

// self_perms is what the last Self a connection was sent since the last
// look says it may do, and whether there was one.
@(private = "file")
self_perms :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
) -> (
	perms: proto.Permissions,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op == .Self {
			_, perms, _, _ = proto.decode_self(e.body)
			told = true
		}
	}
	return
}

@(test)
test_roles :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	owner_acc := ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// Only with Manage_Roles, and a name.
	status, _ := role_set(t, &ts, alice, {name = "moderator", perms = {.Manage_Messages}})
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = role_set(t, &ts, owner, {name = " ", perms = {}})
	testing.expect_value(t, status, proto.Status.Invalid)
	mod: proto.Role_Id
	status, mod = role_set(
		t,
		&ts,
		owner,
		{name = "moderator", perms = {.Manage_Messages, .Manage_Accounts, .Purge}},
	)
	testing.expect_value(t, status, proto.Status.Ok)
	e, told := has_event(ts_events(t, &ts, bob), .Role_Changed)
	testing.expect(t, told, "bob wasn't told of the new role")
	r, _ := proto.decode_role(e.body)
	testing.expect(t, r.id == mod && r.name == "moderator")
	status, _ = role_set(t, &ts, owner, {name = "MODERATOR"})
	testing.expect_value(t, status, proto.Status.Conflict)
	status, _ = role_set(t, &ts, owner, {id = 99, name = "x"})
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Given, it's what the account may do, told at once; and in its record.
	ts_events(t, &ts, alice)
	testing.expect_value(t, roles_give(t, &ts, alice, bob_acc.id, mod), proto.Status.Denied)
	testing.expect_value(t, roles_give(t, &ts, owner, alice_acc.id, mod), proto.Status.Ok)
	testing.expect(t, can(alice_acc, .Purge))
	perms, self_told := self_perms(t, &ts, alice)
	testing.expect(t, self_told, "alice wasn't told what she may do now")
	testing.expect_value(
		t,
		perms,
		proto.Permissions{.Manage_Messages, .Manage_Accounts, .Purge, .Attach_Files},
	)
	e, told = has_event(ts_events(t, &ts, bob), .Account_Changed)
	acc, _ := proto.decode_account(e.body)
	testing.expect(t, told && acc.id == alice_acc.id && len(acc.roles) == 1 && acc.roles[0] == mod)
	testing.expect_value(
		t,
		roles_give(t, &ts, owner, alice_acc.id, proto.EVERYONE_ROLE),
		proto.Status.Invalid,
	)
	testing.expect_value(t, roles_give(t, &ts, owner, alice_acc.id, 99), proto.Status.Invalid)

	// What a role allows changes what its accounts may do, at once.
	status, _ = role_set(
		t,
		&ts,
		owner,
		{id = mod, name = "moderator", perms = {.Manage_Messages, .Manage_Accounts}},
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, !can(alice_acc, .Purge))
	perms, _ = self_perms(t, &ts, alice)
	testing.expect_value(
		t,
		perms,
		proto.Permissions{.Manage_Messages, .Manage_Accounts, .Attach_Files},
	)

	// Everyone's: what a plain member may do. Its name stays, and it stays.
	status, _ = role_set(
		t,
		&ts,
		owner,
		{id = proto.EVERYONE_ROLE, name = "everyone", perms = {.Pin_Messages}},
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, can(bob_acc, .Pin_Messages))
	status, _ = role_set(t, &ts, owner, {id = proto.EVERYONE_ROLE, name = "all", perms = {}})
	testing.expect_value(t, status, proto.Status.Invalid)
	id_buf: [4]u8
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Role_Delete,
		proto.encode_account_id(&id_buf, proto.Account_Id(proto.EVERYONE_ROLE)),
	)
	testing.expect_value(t, status, proto.Status.Invalid)

	// Nobody gives what they haven't got. A lead may manage roles and
	// invite, and that's all they can hand out.
	lead: proto.Role_Id
	status, lead = role_set(t, &ts, owner, {name = "lead", perms = {.Manage_Roles, .Invite}})
	testing.expect_value(t, roles_give(t, &ts, owner, bob_acc.id, lead), proto.Status.Ok)
	status, _ = role_set(t, &ts, bob, {name = "boss", perms = {.Invite, .Purge}})
	testing.expect_value(t, status, proto.Status.Denied)
	inviter: proto.Role_Id
	status, inviter = role_set(t, &ts, bob, {name = "inviter", perms = {.Invite}})
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = role_set(t, &ts, bob, {id = mod, name = "moderator", perms = {}})
	testing.expect(t, status == .Denied, "changed a role above it")
	testing.expect(
		t,
		roles_give(t, &ts, bob, alice_acc.id, mod, inviter) == .Ok,
		"keeping a role it can't give is fine",
	)
	testing.expect(
		t,
		roles_give(t, &ts, bob, alice_acc.id, inviter) == .Denied,
		"took away a role above it",
	)
	testing.expect_value(t, roles_give(t, &ts, bob, owner_acc.id, mod), proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		bob,
		.Role_Delete,
		proto.encode_account_id(&id_buf, proto.Account_Id(mod)),
	)
	testing.expect_value(t, status, proto.Status.Denied)

	// Deleted, nobody has it any more.
	ts_events(t, &ts, alice)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Role_Delete,
		proto.encode_account_id(&id_buf, proto.Account_Id(mod)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, !can(alice_acc, .Manage_Accounts))
	_, told = has_event(ts_events(t, &ts, alice), .Role_Removed)
	testing.expect(t, told)
	testing.expect_value(t, len(alice_acc.roles), 1)
	testing.expect(t, mod not_in s.accounts.roles)
}

@(test)
test_roles_kept :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		ts_account(t, &ts, "admin", "a password", {.Owner})
		alice := ts_account(t, &ts, "alice", "a password")
		owner := logged_in(t, &ts, "admin")
		_, mod := role_set(t, &ts, owner, {name = "moderator", perms = {.Manage_Messages}})
		testing.expect_value(t, roles_give(t, &ts, owner, alice.id, mod), proto.Status.Ok)
	}
	ts: Test_Server
	ts_open(t, &ts, path)
	defer ts_close(&ts)
	alice := account_find(&ts.s.accounts, "alice")
	testing.expect(t, can(alice, .Manage_Messages))
	testing.expect(t, !can(alice, .Purge))
}

@(test)
test_account_disable :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	owner_acc := ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	testing.expect_value(t, disable(t, &ts, alice, bob_acc.id, true), proto.Status.Denied)
	_, mod := role_set(t, &ts, owner, {name = "moderator", perms = {.Manage_Accounts}})
	_, admin_role := role_set(t, &ts, owner, {name = "admin", perms = {.Manage_Accounts, .Purge}})
	roles_give(t, &ts, owner, alice_acc.id, mod)
	roles_give(t, &ts, owner, carol_acc.id, admin_role)

	// Never the owner, nor oneself, nor anyone who may do more.
	testing.expect_value(t, disable(t, &ts, alice, owner_acc.id, true), proto.Status.Invalid)
	testing.expect_value(t, disable(t, &ts, alice, alice_acc.id, true), proto.Status.Invalid)
	testing.expect_value(t, disable(t, &ts, alice, carol_acc.id, true), proto.Status.Denied)
	testing.expect_value(t, disable(t, &ts, alice, 999, true), proto.Status.Not_Found)
	// Nor their password, for the same reason.
	pw_buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ := ts_ask(
		t,
		&ts,
		alice,
		.Account_Password_Set,
		proto.encode_account_password_set(pw_buf[:], carol_acc.id, "another password"),
	)
	testing.expect_value(t, status, proto.Status.Denied)

	// Disabled: logged out, and can't get back in.
	ts_events(t, &ts, bob)
	testing.expect_value(t, disable(t, &ts, alice, bob_acc.id, true), proto.Status.Ok)
	e, told := has_event(ts_events(t, &ts, bob), .Logged_Out)
	testing.expect(t, told && len(e.body) == 1 && proto.Logout_Reason(e.body[0]) == .Disabled)
	testing.expect(t, bob.account == nil)
	testing.expect(t, .Disabled in bob_acc.flags)
	again := ts_connect(&ts, bob.key)
	testing.expect(t, again.account == nil, "a disabled account's device got in")
	status, _ = ts_login(t, &ts, again, "bob", "a password")
	testing.expect(t, status != .Ok)

	// Enabled, its device is let in again.
	testing.expect_value(t, disable(t, &ts, alice, bob_acc.id, false), proto.Status.Ok)
	back := ts_connect(&ts, bob.key)
	testing.expect(t, back.account == bob_acc)
}

@(test)
test_channel_management :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_account(t, &ts, "admin", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	home := s.convs.home
	gaming := conv_by_name(&s.convs, "Gaming")
	testing.expect(t, conv_member_add(&s.convs, gaming, alice.account.id))

	buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	update :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		up: proto.Conv_Update,
	) -> proto.Status {
		buf: [proto.CONV_UPDATE_MAX_SIZE]u8
		status, _ := ts_ask(t, ts, u, .Conv_Update, proto.encode_conv_update(buf[:], up))
		return status
	}
	_ = buf
	testing.expect_value(
		t,
		update(t, &ts, alice, {conv = gaming.id, mask = proto.CONV_UPDATE_NAME, name = "Games"}),
		proto.Status.Denied,
	)
	testing.expect_value(
		t,
		update(t, &ts, owner, {conv = gaming.id, mask = proto.CONV_UPDATE_NAME, name = "lobby"}),
		proto.Status.Conflict,
	)
	testing.expect_value(
		t,
		update(t, &ts, owner, {conv = gaming.id, mask = proto.CONV_UPDATE_NAME, name = "\t"}),
		proto.Status.Invalid,
	)
	status: proto.Status
	ts_events(t, &ts, alice)
	testing.expect_value(
		t,
		update(
			t,
			&ts,
			owner,
			{
				conv = gaming.id,
				mask = proto.CONV_UPDATE_ALL,
				name = "Games",
				topic = "play",
				position = 7,
			},
		),
		proto.Status.Ok,
	)
	e, told := has_event(ts_events(t, &ts, alice), .Conv_Changed)
	c, _ := proto.decode_conv(e.body)
	testing.expect(t, told && c.name == "Games" && c.topic == "play" && c.position == 7)
	// Only what the mask names.
	testing.expect_value(
		t,
		update(
			t,
			&ts,
			owner,
			{conv = gaming.id, mask = proto.CONV_UPDATE_TOPIC, name = "ignored", topic = ""},
		),
		proto.Status.Ok,
	)
	testing.expect(t, gaming.name == "Games" && gaming.topic == "")
	// The home channel may be renamed.
	testing.expect_value(
		t,
		update(t, &ts, owner, {conv = home.id, mask = proto.CONV_UPDATE_NAME, name = "Hall"}),
		proto.Status.Ok,
	)

	// Deleted: archived, out of every list and its room, its name free.
	room_buf: [4]u8
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Voice_Join,
		proto.encode_room(&room_buf, proto.Room(gaming.id)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id_buf: [4]u8
	status, _ = ts_ask(t, &ts, alice, .Conv_Delete, proto.encode_conv_id(&id_buf, gaming.id))
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(t, &ts, owner, .Conv_Delete, proto.encode_conv_id(&id_buf, home.id))
	testing.expect_value(t, status, proto.Status.Invalid)
	ts_events(t, &ts, alice)
	status, _ = ts_ask(t, &ts, owner, .Conv_Delete, proto.encode_conv_id(&id_buf, gaming.id))
	testing.expect_value(t, status, proto.Status.Ok)
	events := ts_events(t, &ts, alice)
	_, told = has_event(events, .Conv_Removed)
	testing.expect(t, told)
	e, told = has_event(events, .Voice_Moved)
	testing.expect(t, told && alice.room == 0)
	testing.expect(t, .Archived in gaming.flags)
	body: []u8
	status, body = ts_ask(t, &ts, alice, .Conv_Browse, nil)
	list_buf: [8]proto.Conv
	_, browsed, _ := proto.decode_browse_page(body, list_buf[:])
	for b in browsed {
		testing.expect(t, b.id != gaming.id, "an archived channel is browsed")
	}
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Voice_Join,
		proto.encode_room(&room_buf, proto.Room(gaming.id)),
	)
	testing.expect_value(t, status, proto.Status.Not_Found)
	create_buf: [proto.CONV_CREATE_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Create,
		proto.encode_conv_create(create_buf[:], "Games", "", false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_private_channels :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, dir))
	ts_account(t, &ts, "admin", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	owner := logged_in(t, &ts, "admin")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	create_buf: [proto.CONV_CREATE_MAX_SIZE]u8
	status, body := ts_ask(
		t,
		&ts,
		owner,
		.Conv_Create,
		proto.encode_conv_create(create_buf[:], "Staff", "", true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	staff_id, _ := proto.decode_conv_id(body)
	staff := conv_by_id(&s.convs, staff_id)
	testing.expect(t, .Private in staff.flags)

	// Something in it: a message and a picture.
	post(t, &ts, owner, staff_id, "secret plans", 1)
	jpeg := test_jpeg(32, 32, 5)
	blob, _ := upload(
		t,
		&ts,
		owner,
		jpeg,
		{kind = .Image, size = len(jpeg), hash = blob_hash(jpeg), width = 32, height = 32},
	)
	post_buf: [proto.MSG_POST_MAX_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Msg_Post,
		proto.encode_msg_post(
			post_buf[:],
			{conv = staff_id, nonce = 2, kind = .Image, blob = blob},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	room_buf: [4]u8
	ts_ask(t, &ts, owner, .Voice_Join, proto.encode_room(&room_buf, proto.Room(staff_id)))

	// Nothing of it reaches anyone else.
	nothing :: proc(
		t: ^testing.T,
		ts: ^Test_Server,
		u: ^Conn,
		conv: proto.Conv_Id,
		blob: proto.Blob_Id,
	) {
		status, body := ts_ask(t, ts, u, .Conv_Browse, nil)
		list_buf: [8]proto.Conv
		_, browsed, _ := proto.decode_browse_page(body, list_buf[:])
		for b in browsed {
			testing.expect(t, b.id != conv, "a private channel is browsed")
		}
		id_buf: [4]u8
		sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
		status, _ = ts_ask(
			t,
			ts,
			u,
			.Conv_Subscribe,
			proto.encode_conv_subscribe(&sub_buf, conv, true),
		)
		testing.expect_value(t, status, proto.Status.Not_Found)
		status, _ = ts_ask(t, ts, u, .Conv_Members, proto.encode_conv_id(&id_buf, conv))
		testing.expect_value(t, status, proto.Status.Not_Found)
		status, _ = ts_ask(t, ts, u, .Msg_History, history_body(conv))
		testing.expect(t, status != .Ok, "a private channel's history was read")
		room_buf: [4]u8
		status, _ = ts_ask(t, ts, u, .Voice_Join, proto.encode_room(&room_buf, proto.Room(conv)))
		testing.expect_value(t, status, proto.Status.Not_Found)
		blob_buf: [proto.BLOB_GET_SIZE]u8
		status, _ = ts_ask(t, ts, u, .Blob_Get, proto.encode_blob_id(&blob_buf, blob))
		testing.expect_value(t, status, proto.Status.Not_Found)
		testing.expect(
			t,
			room_hidden(&ts.s, proto.Room(conv), u.account.id),
			"who's in its room shows",
		)
	}
	nothing(t, &ts, alice, staff_id, blob)
	nothing(t, &ts, bob, staff_id, blob)

	// Adding someone takes Invite and being in it.
	_, inviter := role_set(t, &ts, owner, {name = "inviter", perms = {.Invite}})
	roles_give(t, &ts, owner, alice_acc.id, inviter)
	set_buf: [proto.CONV_MEMBER_SET_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		bob,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, bob_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, bob_acc.id, true),
	)
	testing.expect(t, status == .Not_Found, "added someone to a private channel it isn't in")
	ts_events(t, &ts, alice)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, alice_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	e, told := has_event(ts_events(t, &ts, alice), .Conv_Changed)
	c, _ := proto.decode_conv(e.body)
	// As if subscribed: what's there is read.
	testing.expect(
		t,
		told && c.id == staff_id && c.member && c.unread == 0 && c.read == staff.last_msg,
	)
	testing.expect(t, !room_hidden(&ts.s, proto.Room(staff_id), alice_acc.id))
	status, _ = ts_ask(t, &ts, alice, .Msg_History, history_body(staff_id))
	testing.expect_value(t, status, proto.Status.Ok)
	// And it adds bob, who may leave again.
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, bob_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, bob)
	sub_buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		bob,
		.Conv_Subscribe,
		proto.encode_conv_subscribe(&sub_buf, staff_id, false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	_, told = has_event(ts_events(t, &ts, bob), .Conv_Removed)
	testing.expect(t, told)
	nothing(t, &ts, bob, staff_id, blob)

	// Taken out by someone who manages channels, and out of its room.
	ts_ask(t, &ts, alice, .Voice_Join, proto.encode_room(&room_buf, proto.Room(staff_id)))
	testing.expect_value(t, alice.room, proto.Room(staff_id))
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, alice_acc.id, false),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	ts_events(t, &ts, alice)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, alice_acc.id, false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	events := ts_events(t, &ts, alice)
	_, told = has_event(events, .Conv_Removed)
	testing.expect(t, told)
	testing.expect_value(t, alice.room, 0)
	nothing(t, &ts, alice, staff_id, blob)

	// Not someone who may do more than the asker.
	_, keeper := role_set(t, &ts, owner, {name = "keeper", perms = {.Manage_Channels}})
	roles_give(t, &ts, owner, bob_acc.id, keeper)
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, bob_acc.id, true),
	)
	status, _ = ts_ask(
		t,
		&ts,
		bob,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, staff_id, owner.account.id, false),
	)
	testing.expect_value(t, status, proto.Status.Denied)

	// Out of a public channel isn't a thing.
	gaming := conv_by_name(&s.convs, "Gaming")
	status, _ = ts_ask(
		t,
		&ts,
		owner,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&set_buf, gaming.id, alice_acc.id, false),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
}
