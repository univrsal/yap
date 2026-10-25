package server

import "core:testing"

import "common:proto"

// Tests of deleting accounts (account_delete.odin), on the Test_Server
// of harness_test.odin.

@(private = "file")
delete_account :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	password := "",
) -> proto.Status {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ := ts_ask(
		t,
		ts,
		u,
		.Account_Delete,
		proto.encode_account_delete(buf[:], account, password),
	)
	return status
}

// senders returns who wrote each message on a conversation's newest
// page, as `u` reads it.
@(private = "file")
senders :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	conv: proto.Conv_Id,
) -> (
	ids: [dynamic]proto.Account_Id,
	status: proto.Status,
) {
	ids = make([dynamic]proto.Account_Id, context.temp_allocator)
	buf: [proto.MSG_HISTORY_SIZE]u8
	body: []u8
	status, body = ts_ask(
		t,
		ts,
		u,
		.Msg_History,
		proto.encode_msg_history(&buf, {conv = conv, limit = proto.MAX_HISTORY_LIMIT}),
	)
	if status != .Ok {
		return
	}
	page := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	_, msgs, ok := proto.decode_history_page(body, page)
	testing.expect(t, ok)
	for m in msgs {
		append(&ids, m.sender)
	}
	return
}

@(test)
test_account_delete :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	home := s.convs.home.id
	admin_acc := ts_account(t, &ts, "admin", "a password", {.Owner})
	mod_acc := ts_account(t, &ts, "mod", "a password")
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	admin := logged_in(t, &ts, "admin")
	mod := logged_in(t, &ts, "mod")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// mod can manage accounts, and carol may do more than mod.
	a := &s.accounts
	role_buf: [proto.ROLE_MAX_SIZE]u8
	status, body := ts_ask(
		t,
		&ts,
		admin,
		.Role_Set,
		proto.encode_role(role_buf[:], {name = "mods", perms = {.Manage_Accounts}}),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	mods, _ := proto.decode_account_id(body)
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Role_Set,
		proto.encode_role(role_buf[:], {name = "bosses", perms = {.Manage_Accounts, .Purge}}),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	bosses, _ := proto.decode_account_id(body)
	testing.expect(t, account_roles_set(a, mod_acc, {proto.Role_Id(mods)}))
	testing.expect(t, account_roles_set(a, carol_acc, {proto.Role_Id(bosses)}))

	// What alice leaves behind is a message in the home channel and one
	// in her DM with bob, who has her as a buddy.
	status, _ = post(t, &ts, alice, home, "hello", 1)
	testing.expect_value(t, status, proto.Status.Ok)
	dm: proto.Conv_Id
	status, dm = dm_open_as(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = post(t, &ts, alice, dm, "hi bob", 2)
	testing.expect_value(t, status, proto.Status.Ok)
	buddy_buf: [proto.BUDDY_SET_SIZE]u8
	status, _ = ts_ask(t, &ts, bob, .Buddy_Set, proto.encode_buddy(&buddy_buf, alice_acc.id, true))
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, bob)

	// Deleting is denied without Manage_Accounts and for accounts that may
	// do more than the requester. The owner can never be deleted, and
	// accounts that don't exist can't be found.
	testing.expect_value(t, delete_account(t, &ts, bob, carol_acc.id), proto.Status.Denied)
	testing.expect_value(t, delete_account(t, &ts, mod, carol_acc.id), proto.Status.Denied)
	testing.expect_value(t, delete_account(t, &ts, mod, admin_acc.id), proto.Status.Invalid)
	testing.expect_value(
		t,
		delete_account(t, &ts, admin, admin_acc.id, "a password"),
		proto.Status.Invalid,
	)
	testing.expect_value(t, delete_account(t, &ts, mod, 999), proto.Status.Not_Found)

	// Deleting one's own account requires one's password.
	testing.expect_value(
		t,
		delete_account(t, &ts, alice, alice_acc.id, "not the password"),
		proto.Status.Wrong_Password,
	)
	testing.expect(t, .Deleted not_in alice_acc.flags)
	alice_key := alice.key
	testing.expect_value(
		t,
		delete_account(t, &ts, alice, alice_acc.id, "a password"),
		proto.Status.Ok,
	)

	// Her connection is told about the deletion and no longer belongs to
	// her account. Her device can only log in to some other account.
	e, told := has_event(ts_events(t, &ts, alice), .Logged_Out)
	testing.expect(t, told && len(e.body) == 1 && e.body[0] == u8(proto.Logout_Reason.Deleted))
	testing.expect(t, alice.account == nil)
	testing.expect(t, device_of(a, alice_key) == nil)
	again := ts_connect(&ts, alice_key)
	testing.expect(t, again.account == nil)
	status, _ = ts_login(t, &ts, again, "alice", "a password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)

	// What remains of her account.
	testing.expect_value(t, alice_acc.flags, proto.Account_Flags{.Deleted})
	testing.expect_value(t, alice_acc.display, proto.DELETED_NAME)
	testing.expect_value(t, alice_acc.username, "deleted#3")
	testing.expect(t, !conv_is_member(s.convs.home, alice_acc.id))
	testing.expect(t, account_find(a, "alice") == nil)

	// Everyone is told, and she is removed from bob's buddy list.
	events := ts_events(t, &ts, bob)
	changed := false
	for ev in events {
		if ev.op == .Account_Changed {
			rec, ok := proto.decode_account(ev.body)
			if ok && rec.id == alice_acc.id {
				changed = .Deleted in rec.flags && rec.display == proto.DELETED_NAME
			}
		}
	}
	testing.expect(t, changed, "bob wasn't told alice was deleted")
	e, told = has_event(events, .Buddy_Changed)
	gone, on, _ := proto.decode_buddy(e.body)
	testing.expect(t, told && gone == alice_acc.id && !on)
	testing.expect_value(t, len(bob_acc.buddies), 0)

	// What she wrote stays attributed to her, both in the channel and in
	// the DM. Bob can read the DM but can't write to it or open it again.
	ids, read := senders(t, &ts, bob, home)
	testing.expect_value(t, read, proto.Status.Ok)
	testing.expect(t, len(ids) == 1 && ids[0] == alice_acc.id)
	ids, read = senders(t, &ts, bob, dm)
	testing.expect_value(t, read, proto.Status.Ok)
	testing.expect(t, len(ids) == 1 && ids[0] == alice_acc.id)
	status, _ = post(t, &ts, bob, dm, "are you there?", 3)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = dm_open_as(t, &ts, bob, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Not_Found)
	status, _ = ts_ask(t, &ts, bob, .Buddy_Set, proto.encode_buddy(&buddy_buf, alice_acc.id, true))
	testing.expect_value(t, status, proto.Status.Not_Found)

	// A deleted account can't be deleted again, and her username is free
	// for a new account.
	testing.expect_value(t, delete_account(t, &ts, admin, alice_acc.id), proto.Status.Not_Found)
	create_buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Create,
		proto.encode_account_create(create_buf[:], "alice", "first password", "Alice"),
	)
	testing.expect_value(t, status, proto.Status.Ok)

	// An account with permission can delete somebody else's account,
	// which takes effect immediately.
	testing.expect_value(t, delete_account(t, &ts, admin, mod_acc.id), proto.Status.Ok)
	_, told = has_event(ts_events(t, &ts, mod), .Logged_Out)
	testing.expect(t, told, "mod wasn't told")
	testing.expect(t, .Deleted in mod_acc.flags)

	// The database matches.
	again_loaded: Accounts
	testing.expect(t, accounts_load(&again_loaded, &s.db))
	defer accounts_destroy(&again_loaded)
	kept := account_by_id(&again_loaded, alice_acc.id)
	testing.expect(t, kept != nil && kept.flags == {.Deleted} && kept.username == "deleted#3")
	testing.expect(t, kept != nil && kept.display == proto.DELETED_NAME && len(kept.buddies) == 0)
	testing.expect(t, len(devices_of(&again_loaded, kept)) == 0)
	testing.expect(t, account_find(&again_loaded, "alice") != nil)
}
