package server

import "core:fmt"
import "core:testing"

import "common:proto"

// Tests of registering and invite codes, on the Test_Server of
// auth_test.odin.

@(private = "file")
Reg_Result :: struct {
	status:  proto.Status,
	reason:  proto.Register_Refusal, // when refused with one
	account: proto.Account_Id, // when Ok
}

@(private = "file")
reg :: proc(t: ^testing.T, ts: ^Test_Server, r: proto.Register) -> (out: Reg_Result) {
	u := ts_connect(ts)
	buf: [proto.REGISTER_BODY_MAX]u8
	body: []u8
	out.status, body = ts_ask(t, ts, u, .Register, proto.encode_register(buf[:], r))
	if out.status == .Ok {
		ok: bool
		out.account, _, ok = proto.decode_auth_login_response(body)
		testing.expect(t, ok)
		testing.expect(t, u.account != nil && u.account.id == out.account)
	} else {
		out.reason, _ = proto.decode_register_refusal(body)
	}
	return
}

@(private = "file")
invite_new :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	max_uses: u16,
	expires: proto.Unix_Ms = 0,
) -> (
	status: proto.Status,
	code: string,
) {
	buf: [proto.INVITE_CREATE_SIZE]u8
	body: []u8
	status, body = ts_ask(
		t,
		ts,
		u,
		.Invite_Create,
		proto.encode_invite_create(&buf, max_uses, expires),
	)
	if status == .Ok {
		code, _ = proto.decode_invite_code(body)
	}
	return
}

@(test)
test_register :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "taken", "a password")
	PW :: "a good password"

	// Closed, as servers are unless their config says.
	r := reg(t, &ts, {username = "alice", password = PW})
	testing.expect_value(t, r.status, proto.Status.Denied)
	testing.expect_value(t, r.reason, proto.Register_Refusal.Closed)

	ts.s.registration = {
		open = true,
	}
	r = reg(t, &ts, {username = "x", password = PW})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Username)
	r = reg(t, &ts, {username = "alice", password = "short"})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Password)
	r = reg(t, &ts, {username = "Taken", password = PW})
	testing.expect_value(t, r.status, proto.Status.Conflict)
	testing.expect_value(t, r.reason, proto.Register_Refusal.Username_Taken)
	r = reg(t, &ts, {username = "alice", password = PW, email = "nope"})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Email)
	r = reg(t, &ts, {username = "alice", password = PW, invite = "nope"})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Invite)

	// In: logged in, in the home channel, not having to change anything.
	r = reg(
		t,
		&ts,
		{username = "Alice", password = PW, device = "phone", email = "Alice@Example.org"},
	)
	testing.expect_value(t, r.status, proto.Status.Ok)
	alice := account_by_id(&ts.s.accounts, r.account)
	testing.expect(t, alice != nil)
	if alice == nil {
		return
	}
	testing.expect_value(t, alice.username, "alice")
	testing.expect_value(t, alice.email, "alice@example.org")
	testing.expect(t, .Must_Change not_in alice.flags)
	testing.expect(t, conv_is_member(ts.s.convs.home, alice.id))
	// Its password is what it said.
	status, _ := ts_login(t, &ts, ts_connect(&ts), "alice", PW)
	testing.expect_value(t, status, proto.Status.Ok)

	r = reg(t, &ts, {username = "alice2", password = PW, email = "alice@example.org"})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Email_Taken)

	ts.s.registration = {
		open          = true,
		require_email = true,
	}
	r = reg(t, &ts, {username = "bob", password = PW})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Email_Missing)
	ts.s.registration = {
		open         = true,
		verify_email = true,
	}
	r = reg(t, &ts, {username = "bob", password = PW})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Email_Missing)
	ts.s.registration = {
		open           = true,
		require_invite = true,
	}
	r = reg(t, &ts, {username = "bob", password = PW})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Invite_Missing)

	// Logged in already: no.
	u := ts_connect(&ts)
	ts_login(t, &ts, u, "alice", PW)
	buf: [proto.REGISTER_BODY_MAX]u8
	got, _ := ts_ask(
		t,
		&ts,
		u,
		.Register,
		proto.encode_register(buf[:], {username = "carol", password = PW}),
	)
	testing.expect_value(t, got, proto.Status.Conflict)

	// What the server tells clients.
	testing.expect_value(t, registration_flags(&ts.s), proto.Registration_Flags{.Open, .Invite})
	ts.s.registration = {
		require_invite = true,
	}
	testing.expect_value(t, registration_flags(&ts.s), proto.Registration_Flags{})
}

@(test)
test_register_rate :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts.s.registration = {
		open = true,
	}
	limited := 0
	for i in 0 ..< REGISTER_BURST + 2 {
		name := [?]u8{'u', 's', 'e', 'r', 'a' + u8(i)}
		r := reg(t, &ts, {username = string(name[:]), password = "a good password"})
		if r.status == .Rate_Limited {
			limited += 1
		}
	}
	testing.expect_value(t, limited, 2)
}

@(test)
test_invites :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts.s.registration = {
		open           = true,
		require_invite = true,
	}
	ts_account(t, &ts, "owner", "owner's password", {.Owner})
	ts_account(t, &ts, "plain", "plain password")
	owner := ts_connect(&ts)
	plain := ts_connect(&ts)
	ts_login(t, &ts, owner, "owner", "owner's password")
	ts_login(t, &ts, plain, "plain", "plain password")
	PW :: "a good password"

	// It takes Create_Invites.
	status, code := invite_new(t, &ts, plain, 1)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = invite_new(t, &ts, owner, proto.MAX_INVITE_USES + 1)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = invite_new(t, &ts, owner, 1, proto.Unix_Ms(unix_ms() - 1000))
	testing.expect_value(t, status, proto.Status.Invalid)

	status, code = invite_new(t, &ts, owner, 1)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(code), proto.INVITE_CODE_SIZE)
	code = clone_temp(code)

	// Any case; then used up.
	lower := to_lower_temp(code)
	r := reg(t, &ts, {username = "first", password = PW, invite = lower})
	testing.expect_value(t, r.status, proto.Status.Ok)
	r = reg(t, &ts, {username = "second", password = PW, invite = code})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Invite)

	// Who registered with which, for Manage_Accounts only.
	id_buf: [4]u8
	got, body := ts_ask(t, &ts, owner, .Invite_Of, proto.encode_account_id(&id_buf, r.account))
	testing.expect_value(t, got, proto.Status.Not_Found) // "second" never was
	first := account_find(&ts.s.accounts, "first")
	got, body = ts_ask(t, &ts, owner, .Invite_Of, proto.encode_account_id(&id_buf, first.id))
	testing.expect_value(t, got, proto.Status.Ok)
	of_code, creator, of_ok := proto.decode_invite_of(body)
	testing.expect(t, of_ok)
	testing.expect_value(t, of_code, code)
	testing.expect_value(t, creator, owner.account.id)
	got, _ = ts_ask(t, &ts, plain, .Invite_Of, proto.encode_account_id(&id_buf, first.id))
	testing.expect_value(t, got, proto.Status.Denied)

	// Expired: no good.
	status, code = invite_new(t, &ts, owner, 0, proto.Unix_Ms(unix_ms() + 100_000))
	testing.expect_value(t, status, proto.Status.Ok)
	code = clone_temp(code)
	expire := fmt.tprintf("UPDATE invites SET expires = 1 WHERE code = '%s'", code)
	testing.expect(t, db_exec(&ts.s.db, expire))
	r = reg(t, &ts, {username = "third", password = PW, invite = code})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Invite)

	// Revoked: by its maker or Manage_Accounts, not anybody.
	status, code = invite_new(t, &ts, owner, 0)
	code = clone_temp(code)
	cb: [1 + proto.INVITE_CODE_SIZE]u8
	got, _ = ts_ask(t, &ts, plain, .Invite_Revoke, proto.encode_invite_code(&cb, code))
	testing.expect_value(t, got, proto.Status.Denied)
	r = reg(t, &ts, {username = "fourth", password = PW, invite = code})
	testing.expect_value(t, r.status, proto.Status.Ok)
	r = reg(t, &ts, {username = "fifth", password = PW, invite = code})
	testing.expect_value(t, r.status, proto.Status.Ok) // any number of uses
	got, _ = ts_ask(t, &ts, owner, .Invite_Revoke, proto.encode_invite_code(&cb, code))
	testing.expect_value(t, got, proto.Status.Ok)
	r = reg(t, &ts, {username = "sixth", password = PW, invite = code})
	testing.expect_value(t, r.reason, proto.Register_Refusal.Invite)

	// Listed: everybody's for Manage_Accounts, with their uses.
	got, body = ts_ask(t, &ts, owner, .Invite_List)
	testing.expect_value(t, got, proto.Status.Ok)
	invites, list_ok := proto.decode_invites(body)
	testing.expect(t, list_ok)
	testing.expect_value(t, len(invites), 3)
	if len(invites) == 3 {
		testing.expect_value(t, invites[0].code, code) // newest first
		testing.expect_value(t, invites[0].uses, 2)
		testing.expect(t, invites[0].revoked)
	}
	got, _ = ts_ask(t, &ts, plain, .Invite_List)
	testing.expect_value(t, got, proto.Status.Denied)

	// Not required, still counted.
	ts.s.registration = {
		open = true,
	}
	status, code = invite_new(t, &ts, owner, 3)
	code = clone_temp(code)
	r = reg(t, &ts, {username = "seventh", password = PW, invite = code})
	testing.expect_value(t, r.status, proto.Status.Ok)
	inv, found := invite_get(&ts.s.db, code)
	testing.expect(t, found && inv.uses == 1)

	// A deleted account's codes go with it.
	testing.expect(t, account_erase(&ts.s, owner.account))
	inv, found = invite_get(&ts.s.db, code)
	testing.expect(t, found && inv.revoked)
}

@(private = "file")
clone_temp :: proc(s: string) -> string {
	out := make([]u8, len(s), context.temp_allocator)
	copy(out, s)
	return string(out)
}

@(private = "file")
to_lower_temp :: proc(s: string) -> string {
	out := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		out[i] = s[i] + ('a' - 'A') if s[i] >= 'A' && s[i] <= 'Z' else s[i]
	}
	return string(out)
}
