package server

import "core:testing"

import "common:proto"

// Tests of bans (bans.odin).

@(private = "file")
ban_as :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	account: proto.Account_Id,
	on: bool,
	reason := "",
	purge := proto.Ban_Purge.None,
) -> proto.Status {
	buf: [proto.BAN_SET_MAX_SIZE]u8
	body := proto.encode_ban_set(&buf, {account = account, on = on, reason = reason, purge = purge})
	status, _ := ts_ask(t, ts, u, .Ban_Set, body)
	return status
}

// told_banned returns the reason of the Logged_Out(Banned) a connection was
// sent since its events were last read, and whether there was one.
@(private = "file")
told_banned :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (reason: string, told: bool) {
	for e in ts_events(t, ts, u) {
		if e.op == .Logged_Out {
			why, text := proto.decode_logged_out(e.body)
			if why == .Banned {
				reason, told = text, true
			}
		}
	}
	return
}

@(test)
test_ban :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	s.registration = {
		open = true,
	}
	ts_account(t, &ts, "olga", "a password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	testing.expect(t, account_set_email(&s.accounts, bob_acc, "bob@example.org"))
	olga := logged_in(t, &ts, "olga")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	bob_phone := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	alice_acc.perms += {.Ban_Members}

	// Only with Ban_Members, and only someone we outrank.
	testing.expect_value(t, ban_as(t, &ts, carol, bob_acc.id, true), proto.Status.Denied)
	carol_acc.perms += {.Ban_Members, .Purge}
	testing.expect_value(t, ban_as(t, &ts, alice, carol_acc.id, true), proto.Status.Denied)
	testing.expect_value(t, ban_as(t, &ts, alice, alice_acc.id, true), proto.Status.Invalid)
	testing.expect_value(t, ban_as(t, &ts, alice, 999, true), proto.Status.Not_Found)
	// Removing messages with it isn't there yet.
	testing.expect_value(
		t,
		ban_as(t, &ts, alice, bob_acc.id, true, purge = .Day),
		proto.Status.Invalid,
	)
	testing.expect(t, .Disabled not_in bob_acc.flags)

	// Every device of bob's is logged out, and told why.
	testing.expect_value(
		t,
		ban_as(t, &ts, alice, bob_acc.id, true, "spam\nand more spam"),
		proto.Status.Ok,
	)
	testing.expect(t, .Disabled in bob_acc.flags)
	for u in ([]^Conn{bob, bob_phone}) {
		reason, told := told_banned(t, &ts, u)
		testing.expect(t, told)
		testing.expect_value(t, reason, "spam and more spam")
		testing.expect(t, u.account == nil)
	}

	// A device of bob's that connects again is told again.
	key := bob.key
	ts_disconnect(&ts, bob)
	again := ts_connect(&ts, key)
	testing.expect(t, again.account == nil)
	reason, told := told_banned(t, &ts, again)
	testing.expect(t, told)
	testing.expect_value(t, reason, "spam and more spam")

	// A login with the right password is answered with the reason, but a
	// wrong one doesn't learn of the ban.
	stranger := ts_connect(&ts)
	status, _ := ts_login(t, &ts, stranger, "bob", "not the password")
	testing.expect_value(t, status, proto.Status.Wrong_Password)
	buf: [proto.ACCOUNT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		stranger,
		.Auth_Login,
		proto.encode_auth_login(buf[:], "bob", "a password", "laptop", "test"),
	)
	testing.expect_value(t, status, proto.Status.Banned)
	testing.expect_value(t, proto.decode_banned(body), "spam and more spam")
	testing.expect(t, stranger.account == nil)

	// Nobody can register with bob's address, even once bob no longer has it.
	testing.expect(t, account_set_email(&s.accounts, bob_acc, ""))
	reg_buf: [proto.REGISTER_BODY_MAX]u8
	status, body = ts_ask(
		t,
		&ts,
		ts_connect(&ts),
		.Register,
		proto.encode_register(
			reg_buf[:],
			{username = "bob2", password = "a password", email = "Bob@example.org"},
		),
	)
	testing.expect_value(t, status, proto.Status.Conflict)
	refusal, _ := proto.decode_register_refusal(body)
	testing.expect_value(t, refusal, proto.Register_Refusal.Email_Taken)

	// The ban list, for Ban_Members only.
	status, _ = ts_ask(t, &ts, olga, .Ban_List)
	testing.expect_value(t, status, proto.Status.Ok)
	alice_acc.perms -= {.Ban_Members}
	status, _ = ts_ask(t, &ts, alice, .Ban_List)
	testing.expect_value(t, status, proto.Status.Denied)
	alice_acc.perms += {.Ban_Members}
	status, body = ts_ask(t, &ts, alice, .Ban_List)
	testing.expect_value(t, status, proto.Status.Ok)
	bans, ok := proto.decode_bans(body)
	testing.expect(t, ok)
	testing.expect_value(t, len(bans), 1)
	if len(bans) == 1 {
		testing.expect_value(t, bans[0].account, bob_acc.id)
		testing.expect_value(t, bans[0].by, alice_acc.id)
		testing.expect_value(t, bans[0].reason, "spam and more spam")
	}

	// The ban is in the database.
	loaded: Accounts
	testing.expect(t, accounts_load(&loaded, &s.db))
	b, banned := ban_of(&loaded, bob_acc.id)
	testing.expect(t, banned)
	testing.expect_value(t, b.email, "bob@example.org")
	testing.expect_value(t, b.by, alice_acc.id)
	accounts_destroy(&loaded)

	// Unbanning lets bob log in again and frees the address.
	testing.expect_value(t, ban_as(t, &ts, carol, bob_acc.id, false), proto.Status.Ok)
	testing.expect_value(t, ban_as(t, &ts, carol, bob_acc.id, false), proto.Status.Not_Found)
	testing.expect(t, .Disabled not_in bob_acc.flags)
	testing.expect(t, !email_banned(&s.accounts, "bob@example.org"))
	status, _ = ts_login(t, &ts, ts_connect(&ts), "bob", "a password")
	testing.expect_value(t, status, proto.Status.Ok)

	// Enabling a banned account with Account_Disable ends the ban too.
	testing.expect_value(t, ban_as(t, &ts, alice, bob_acc.id, true), proto.Status.Ok)
	disable_buf: [proto.ACCOUNT_DISABLE_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		olga,
		.Account_Disable,
		proto.encode_account_disable(&disable_buf, bob_acc.id, false),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	_, banned = ban_of(&s.accounts, bob_acc.id)
	testing.expect(t, !banned)
	testing.expect(t, .Disabled not_in bob_acc.flags)

	// A disabled account that isn't banned is still just Denied.
	status, _ = ts_ask(
		t,
		&ts,
		olga,
		.Account_Disable,
		proto.encode_account_disable(&disable_buf, bob_acc.id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, ts_connect(&ts), "bob", "a password")
	testing.expect_value(t, status, proto.Status.Denied)
}
