#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of logging in and out (auth.odin), with the server's end played by
// the harness.

@(private = "file")
login_of :: proc(t: ^testing.T, r: Test_Request) -> (username, password, device: string) {
	testing.expect_value(t, r.op, proto.Request_Op.Auth_Login)
	ok: bool
	username, password, device, _, ok = proto.decode_auth_login(r.body)
	testing.expect(t, ok)
	return
}

// self tells the client who it is, which finishes a login.
@(private = "file")
self :: proc(tc: ^Test_Conn, id: proto.Account_Id, flags: proto.Account_Flags = {}) {
	buf: [proto.SELF_SIZE]u8
	tc_event(tc, .Self, proto.encode_self(&buf, id, {}, flags))
}

@(test)
test_login_when_the_server_asks :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// With nothing to log in with, the server's request for a login waits for one.
	auth_restart(c, false)
	testing.expect_value(t, c.auth.state, Login_State.Needed)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	auth_login(c, {username = "alice", password = "correct horse", device = "laptop"})
	testing.expect_value(t, c.auth.state, Login_State.Working)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	user, password, device := login_of(t, sent[0])
	testing.expect_value(t, user, "alice")
	testing.expect_value(t, password, "correct horse")
	testing.expect_value(t, device, "laptop")

	// Logging in again while one is under way, or after, does nothing.
	auth_login(c, {username = "mallory", password = "x", device = "y"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// The password is forgotten once it was accepted, and Self finishes it.
	tc_answer(&tc, sent[0].id, .Ok)
	testing.expect_value(t, c.auth.password, "")
	testing.expect_value(t, c.auth.state, Login_State.Working)
	self(&tc, 7)
	testing.expect_value(t, c.auth.state, Login_State.Done)
	testing.expect_value(t, c.auth.me, proto.Account_Id(7))

	// Scripts are told that we are connected, once.
	events := tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	_, connected := events[0].(Event_Connected)
	testing.expect(t, connected)
	self(&tc, 7)
	testing.expect_value(t, len(tc_events(&tc)), 0)
}

@(test)
test_login_with_given_credentials :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// Credentials given before connecting are used as soon as the server wants a login.
	auth_credentials(c, "Alice", "correct horse", "laptop")
	auth_restart(c, false)
	testing.expect_value(t, c.auth.state, Login_State.Working)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	user, password, _ := login_of(t, sent[0])
	testing.expect_value(t, user, "alice") // as the server expects it
	testing.expect_value(t, password, "correct horse")

	// If the connection starts over before the answer, the login is repeated
	// on the new one, because the password is still needed.
	tc_restart(&tc)
	testing.expect_value(t, c.auth.password, "correct horse")
	auth_restart(c, false)
	sent = tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	_, password, _ = login_of(t, sent[0])
	testing.expect_value(t, password, "correct horse")
	testing.expect_value(t, c.auth.state, Login_State.Working)
}

@(test)
test_known_device_is_logged_in_by_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// Even with credentials around, a device the server knows needs no login.
	auth_credentials(c, "alice", "correct horse", "laptop")
	auth_restart(c, true)
	testing.expect_value(t, c.auth.state, Login_State.Working)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
}

@(test)
test_login_refusals :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the warnings are expected

	Refusal :: struct {
		status: proto.Status,
		error:  string,
	}
	refusals := []Refusal {
		{.Wrong_Password, "Wrong username or password."},
		{.Rate_Limited, "Too many login attempts. Wait a moment and try again."},
		{.Denied, "This account is disabled."},
		{.Banned, "This account is banned."},
		{.Internal, "The server failed to log you in (Internal)."},
	}
	for r in refusals {
		tc: Test_Conn
		tc_open(&tc)
		defer tc_close(&tc)
		c := &tc.c

		auth_restart(c, false)
		auth_login(c, {username = "alice", password = "wrong one", device = "laptop"})
		sent := tc_sent(t, &tc)
		tc_answer(&tc, sent[0].id, r.status)
		testing.expectf(t, c.auth.state == .Needed, "%v: %v", r.status, c.auth.state)
		testing.expect_value(t, c.auth.error, r.error)
		// A refused password is not kept to try again.
		testing.expectf(t, c.auth.password == "", "%v: the password was kept", r.status)
		testing.expectf(t, c.auth.banned == (r.status == .Banned), "%v: banned", r.status)

		// A new try is possible.
		auth_login(c, {username = "alice", password = "right one", device = "laptop"})
		testing.expect_value(t, c.auth.state, Login_State.Working)
		testing.expect_value(t, c.auth.error, "")
		testing.expect_value(t, len(tc_sent(t, &tc)), 1)
	}
}

@(test)
test_login_too_long_is_not_sent :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	auth_restart(c, false)
	long := make([]u8, 3 * proto.ACCOUNT_BODY_MAX, context.temp_allocator)
	for &b in long {
		b = 'x'
	}
	auth_login(c, {username = "alice", password = string(long), device = "laptop"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, c.auth.state, Login_State.Needed)
	testing.expect_value(t, c.auth.error, "The username or password is too long.")
	testing.expect_value(t, c.auth.password, "")
}

@(test)
test_logged_out_by_the_server :: proc(t: ^testing.T) {
	context.logger = expected_errors() // the warnings are expected

	Case :: struct {
		reason: proto.Logout_Reason,
		text:   string,
		error:  string,
	}
	cases := []Case {
		{.Banned, "spam", "This account is banned."},
		{.Revoked, "", "This device was logged out from another device."},
		{.Password_Changed, "", "The account's password was changed. Please log in again."},
		{.Disabled, "", "The account has been disabled."},
		{.Deleted, "", "The account has been deleted."},
	}
	for k in cases {
		tc: Test_Conn
		open_logged_in(&tc)
		defer tc_close(&tc)
		c := &tc.c

		buf: [proto.LOGGED_OUT_MAX_SIZE]u8
		tc_event(&tc, .Logged_Out, proto.encode_logged_out(&buf, k.reason, k.text))
		testing.expectf(t, c.auth.state == .Needed, "%v: %v", k.reason, c.auth.state)
		testing.expect_value(t, c.auth.error, k.error)
		testing.expect_value(t, c.auth.me, proto.Account_Id(0))
		testing.expect_value(t, len(c.auth.accounts), 0)
		testing.expect_value(t, len(c.convs.convs), 0)
		testing.expect_value(t, c.auth.banned, k.reason == .Banned)
		if k.reason == .Banned {
			testing.expect_value(t, c.auth.ban_reason, "spam")
		}
	}
}

@(private = "file")
open_logged_in :: proc(tc: ^Test_Conn) {
	tc_open(tc)
	auth_restart(&tc.c, true)
	self(tc, 1)
	tc_account(tc, 1, "bob")
	tc_conv(tc, 1, "Lobby")
	_ = tc_events(tc)
}

@(test)
test_logout :: proc(t: ^testing.T) {
	context.logger = expected_errors()
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// Not logged in: nothing to log out of.
	auth_logout(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	open_logged_in(&tc)
	testing.expect_value(t, c.auth.state, Login_State.Done)
	auth_logout(c)
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Auth_Logout)
	// Still logged in until the server says so.
	testing.expect_value(t, c.auth.state, Login_State.Done)

	tc_answer(&tc, sent[0].id, .Ok)
	testing.expect_value(t, c.auth.state, Login_State.Needed)
	testing.expect_value(t, c.auth.error, "")
	testing.expect_value(t, c.auth.me, proto.Account_Id(0))
	testing.expect_value(t, len(c.auth.accounts), 0)
	testing.expect_value(t, len(c.convs.convs), 0)
}

@(test)
test_logout_refused_stays_logged_in :: proc(t: ^testing.T) {
	context.logger = expected_errors()
	tc: Test_Conn
	open_logged_in(&tc)
	defer tc_close(&tc)
	c := &tc.c

	auth_logout(c)
	sent := tc_sent(t, &tc)
	tc_answer(&tc, sent[0].id, .Internal)
	testing.expect_value(t, c.auth.state, Login_State.Done)
	testing.expect_value(t, c.auth.me, proto.Account_Id(1))
}

@(test)
test_password_change :: proc(t: ^testing.T) {
	context.logger = expected_errors()
	tc: Test_Conn
	open_logged_in(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// A password the server would refuse isn't sent.
	auth_password(c, {old = "old password", new = "short"})
	long := make([]u8, proto.MAX_ACCOUNT_PASSWORD + 1, context.temp_allocator)
	for &b in long {
		b = 'x'
	}
	auth_password(c, {old = "old password", new = string(long)})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	// The password we log in with is out of date whatever the answer.
	auth_credentials(c, "bob", "old password", "laptop")
	auth_password(c, {old = "old password", new = "new password"})
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Password_Change)
	tc_answer(&tc, sent[0].id, .Wrong_Password)
	testing.expect_value(t, c.auth.password, "")
}

@(test)
test_email_change :: proc(t: ^testing.T) {
	context.logger = expected_errors()
	tc: Test_Conn
	open_logged_in(&tc)
	defer tc_close(&tc)
	c := &tc.c

	auth_email(c, "not an address")
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	auth_email(c, "  bob@example.org ")
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Email_Set)

	// An empty address removes the email address.
	auth_email(c, "  ")
	sent = tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 1)
	testing.expect_value(t, sent[0].op, proto.Request_Op.Email_Set)
}

@(test)
test_directory_follows_the_server :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_logged_in(&tc)
	defer tc_close(&tc)
	c := &tc.c

	buf: [1024]u8
	tell :: proc(tc: ^Test_Conn, buf: []u8, a: proto.Account) {
		tc_event(tc, .Account_Changed, proto.encode_account(buf, a))
	}
	tell(&tc, buf[:], {id = 2, username = "alice", display = "Alice"})
	testing.expect_value(t, account_display(c, 2), "Alice")
	testing.expect_value(t, account_by_username(c, "alice"), proto.Account_Id(2))

	// A change replaces what was there.
	tell(&tc, buf[:], {id = 2, username = "alice", display = "Alice B.", status = "out"})
	testing.expect_value(t, account_display(c, 2), "Alice B.")
	testing.expect_value(t, c.auth.accounts[2].status, "out")
	testing.expect_value(t, len(c.auth.accounts), 2)

	// Unknown accounts have no name, and no username.
	testing.expect_value(t, account_display(c, 99), "")
	testing.expect_value(t, account_by_username(c, "nobody"), proto.Account_Id(0))

	// A new sync starts from nothing.
	tc_event(&tc, .Sync_Begin)
	testing.expect_value(t, len(c.auth.accounts), 0)
}

@(test)
test_status_text_wording :: proc(t: ^testing.T) {
	testing.expect(t, status_text(.Denied) != "")
	testing.expect(t, status_text(.Conflict, "account") != status_text(.Conflict))
	testing.expect_value(t, status_text(.Not_Found, "channel"), "That channel no longer exists.")
	testing.expect_value(t, status_text(.Not_Found), "That no longer exists on the server.")
	// Anything else names the status, so that a bug report can say what happened.
	testing.expect_value(
		t,
		status_text(.Internal),
		"The server failed to complete the request (Internal).",
	)
}
