package server

import "core:testing"

import "common:proto"

@(private = "file")
admin_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	account: proto.Account_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.CONV_MEMBER_SET_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Conv_Admin_Set, proto.encode_conv_member_set(&buf, conv, account, on))
	return status
}

@(private = "file")
member_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
	account: proto.Account_Id,
	on: bool,
) -> proto.Status {
	buf: [proto.CONV_MEMBER_SET_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Conv_Member_Set, proto.encode_conv_member_set(&buf, conv, account, on))
	return status
}

@(private = "file")
update :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, up: proto.Conv_Update) -> proto.Status {
	buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	status, _ := ts_ask(t, ts, u, .Conv_Update, proto.encode_conv_update(buf[:], up))
	return status
}

// admins_of returns who Conv_Members says are a channel's admins.
@(private = "file")
admins_of :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> []proto.Account_Id {
	id_buf: [4]u8
	status, body := ts_ask(t, ts, u, .Conv_Members, proto.encode_conv_id(&id_buf, conv))
	testing.expect_value(t, status, proto.Status.Ok)
	buf := make([]proto.Account_Id, 16, context.temp_allocator)
	admins, ok := proto.decode_conv_admins(body, buf)
	testing.expect(t, ok)
	return admins
}

// told_admin returns whether the last Conv_Changed about `conv` that a
// connection was sent says that it is an admin there, and whether there was
// one.
@(private = "file")
told_admin :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> (
	admin: bool,
	told: bool,
) {
	for e in ts_events(t, ts, u) {
		if e.op != .Conv_Changed {
			continue
		}
		c, ok := proto.decode_conv(e.body)
		testing.expect(t, ok)
		if c.id == conv {
			admin, told = c.admin, true
		}
	}
	return
}

@(test)
test_channel_admins :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	owner_acc := ts_account(t, &ts, "owner", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	owner := logged_in(t, &ts, "owner")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")

	// Whoever makes a channel is its first admin.
	create_buf: [proto.CONV_CREATE_MAX_SIZE]u8
	status, created := ts_ask(
		t,
		&ts,
		owner,
		.Conv_Create,
		proto.encode_conv_create(create_buf[:], "team", "", true, {}),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	team, _ := proto.decode_conv_id(created)
	admin, told := told_admin(t, &ts, owner, team)
	testing.expect(t, told && admin)
	testing.expect_value(t, member_set(t, &ts, owner, team, alice_acc.id, true), proto.Status.Ok)
	ts_events(t, &ts, alice)

	// Alice may neither add people (she lacks Invite) nor rename it, until she
	// is one of its admins, which she is told.
	testing.expect_value(t, member_set(t, &ts, alice, team, bob_acc.id, true), proto.Status.Denied)
	testing.expect_value(t, admin_set(t, &ts, alice, team, alice_acc.id, true), proto.Status.Denied)
	testing.expect_value(t, admin_set(t, &ts, owner, team, alice_acc.id, true), proto.Status.Ok)
	admin, told = told_admin(t, &ts, alice, team)
	testing.expect(t, told && admin)
	admins := admins_of(t, &ts, alice, team)
	testing.expect(t, len(admins) == 2 && admins[0] == owner_acc.id && admins[1] == alice_acc.id)

	// An admin adds and removes members, and changes the name and topic, but
	// not the rest.
	testing.expect_value(t, member_set(t, &ts, alice, team, bob_acc.id, true), proto.Status.Ok)
	testing.expect_value(t, member_set(t, &ts, alice, team, carol_acc.id, true), proto.Status.Ok)
	testing.expect_value(t, member_set(t, &ts, alice, team, carol_acc.id, false), proto.Status.Ok)
	testing.expect_value(t, member_set(t, &ts, alice, team, owner_acc.id, false), proto.Status.Denied)
	testing.expect_value(
		t,
		update(
			t,
			&ts,
			alice,
			{conv = team, mask = proto.CONV_UPDATE_NAME | proto.CONV_UPDATE_TOPIC, name = "crew", topic = "us"},
		),
		proto.Status.Ok,
	)
	conv := conv_by_id(&s.convs, team)
	testing.expect(t, conv.name == "crew" && conv.topic == "us")
	testing.expect_value(
		t,
		update(t, &ts, alice, {conv = team, mask = proto.CONV_UPDATE_POSITION, position = 9}),
		proto.Status.Denied,
	)
	testing.expect_value(
		t,
		update(t, &ts, bob, {conv = team, mask = proto.CONV_UPDATE_TOPIC, topic = "mine"}),
		proto.Status.Denied,
	)
	delete_buf: [4]u8
	status, _ = ts_ask(t, &ts, alice, .Conv_Delete, proto.encode_conv_id(&delete_buf, team))
	testing.expect_value(t, status, proto.Status.Denied)

	// An admin makes others admins, but only stops being one themselves.
	testing.expect_value(t, admin_set(t, &ts, alice, team, bob_acc.id, true), proto.Status.Ok)
	testing.expect_value(t, admin_set(t, &ts, alice, team, bob_acc.id, false), proto.Status.Denied)
	ts_events(t, &ts, bob)
	testing.expect_value(t, admin_set(t, &ts, bob, team, bob_acc.id, false), proto.Status.Ok)
	admin, told = told_admin(t, &ts, bob, team)
	testing.expect(t, told && !admin)
	// Only members, and only in channels.
	testing.expect_value(t, admin_set(t, &ts, alice, team, carol_acc.id, true), proto.Status.Not_Found)
	testing.expect_value(t, admin_set(t, &ts, carol, team, carol_acc.id, true), proto.Status.Not_Found)
	dm_buf: [4]u8
	_, dm_body := ts_ask(t, &ts, alice, .DM_Open, proto.encode_account_id(&dm_buf, bob_acc.id))
	dm, _ := proto.decode_conv_id(dm_body)
	testing.expect_value(t, admin_set(t, &ts, alice, dm, bob_acc.id, true), proto.Status.Not_Found)

	// Those who manage channels may make an admin no longer one.
	testing.expect_value(t, admin_set(t, &ts, owner, team, alice_acc.id, false), proto.Status.Ok)
	admins = admins_of(t, &ts, owner, team)
	testing.expect(t, len(admins) == 1 && admins[0] == owner_acc.id)
	testing.expect_value(
		t,
		update(t, &ts, alice, {conv = team, mask = proto.CONV_UPDATE_TOPIC, topic = "again"}),
		proto.Status.Denied,
	)

	// Leaving a channel ends being its admin.
	testing.expect_value(t, admin_set(t, &ts, owner, team, bob_acc.id, true), proto.Status.Ok)
	testing.expect_value(t, member_set(t, &ts, bob, team, bob_acc.id, false), proto.Status.Ok)
	testing.expect_value(t, member_set(t, &ts, owner, team, bob_acc.id, true), proto.Status.Ok)
	testing.expect(t, !conv_admin(conv, bob_acc.id))

	// It is kept in the database.
	testing.expect_value(t, admin_set(t, &ts, owner, team, alice_acc.id, true), proto.Status.Ok)
	q := db_query(&s.db, .Member_All)
	found := 0
	for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		if db_col_int(q, 0) == i64(team) && db_col_int(q, 4) != 0 {
			found += 1
		}
	}
	testing.expect_value(t, found, 2)
}
