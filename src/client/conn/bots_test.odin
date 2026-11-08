#+build !wasi
package conn

import "core:crypto/ecdh"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests of creating bots and their tokens (bots.odin). The token is made here
// and only its public half goes to the server; it is shown once and forgotten.

@(private = "file")
open_bots :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "root", "Root")
	return tc_view(tc)
}

// public_of returns the public half of a token.
@(private = "file")
public_of :: proc(t: ^testing.T, token: string) -> [proto.KEY_SIZE]u8 {
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	testing.expect(t, proto.bot_token_parse(token, &key), "not a token")
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(&key, pub[:])
	return pub
}

@(test)
test_creating_a_bot :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	defer auth_bot_token_forget(&tc.c)
	c := &tc.c

	auth_bot_create(c, {username = "Helper-Bot", display = "Helper"})
	req, ok := tc_one(t, &tc, .Bot_Create)
	testing.expect(t, ok)
	username, display, key, device, dec := proto.decode_bot_create(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, username, "helper-bot") // as the server expects it
	testing.expect_value(t, display, "Helper")
	testing.expect_value(t, device, BOT_TOKEN_DEVICE)

	// The token is kept here until the server accepts it, and the server got
	// only the public half of it.
	token := strings.clone(c.auth.bot_token)
	defer delete(token)
	testing.expect(t, strings.has_prefix(token, proto.BOT_TOKEN_PREFIX))
	testing.expect_value(t, key, public_of(t, token))
	testing.expect_value(t, v.bot_token, "")

	buf: [4]u8
	tc_answer(&tc, req.id, .Ok, proto.encode_account_id(&buf, 42))
	// Now it is the UI's, once, and not kept here.
	testing.expect_value(t, v.bot_token, token)
	testing.expect_value(t, v.bot_token_account, proto.Account_Id(42))
	testing.expect_value(t, v.bot_token_count, 1)
	testing.expect_value(t, c.auth.bot_token, "")
	testing.expect_value(
		t,
		v.notice.text,
		"Bot created. Copy its token now, because it will not be shown again.",
	)
	testing.expect(t, v.notice.ok)

	// Forgetting it removes it from the UI too.
	auth_bot_token_forget(c)
	testing.expect_value(t, v.bot_token, "")
	testing.expect_value(t, v.bot_token_account, proto.Account_Id(0))
}

@(test)
test_bot_name_is_checked :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	for bad in ([]string{"", "has space", "UPPER CASE", "bad/slash", "x\x00y"}) {
		create := Bot_Create_Command {
			username = strings.clone(bad),
			display  = strings.clone("d"),
		}
		auth_bot_create(&tc.c, create)
		command_destroy(create)
		testing.expectf(t, len(tc_sent(t, &tc)) == 0, "%q was sent", bad)
		testing.expect_value(t, v.notice.text, username_rule())
		testing.expect_value(t, tc.c.auth.bot_token, "")
	}
}

@(test)
test_bot_creation_fails :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	c := &tc.c

	for status in ([]proto.Status{.Conflict, .Denied, .Internal}) {
		auth_bot_create(c, {username = "helper-bot", display = "Helper"})
		req, _ := tc_one(t, &tc, .Bot_Create)
		testing.expect(t, c.auth.bot_token != "")
		tc_answer(&tc, req.id, status)
		// The token is thrown away, and nothing is shown.
		testing.expect_value(t, c.auth.bot_token, "")
		testing.expect_value(t, v.bot_token, "")
		testing.expect_value(t, v.notice.text, status_text(status, "account"))
		testing.expect(t, !v.notice.ok)
	}
	// Ok without the account that was made is a failure too.
	auth_bot_create(c, {username = "helper-bot", display = "Helper"})
	req, _ := tc_one(t, &tc, .Bot_Create)
	tc_answer(&tc, req.id, .Ok, []u8{1})
	testing.expect_value(t, c.auth.bot_token, "")
	testing.expect_value(t, v.bot_token, "")
	testing.expect_value(t, v.bot_token_count, 0)
}

@(test)
test_only_one_token_is_kept :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_bots(&tc)
	defer tc_close(&tc)
	defer auth_bot_token_forget(&tc.c)
	c := &tc.c

	auth_bot_create(c, {username = "helper-bot", display = "Helper"})
	first := strings.clone(c.auth.bot_token)
	defer delete(first)
	auth_bot_create(c, {username = "other-bot", display = "Other"})
	testing.expect(t, c.auth.bot_token != first, "a new token did not replace the old")
	sent := tc_sent(t, &tc)
	testing.expect_value(t, len(sent), 2)
	// Each request carries the public half of its own token.
	if len(sent) == 2 {
		_, _, key1, _, _ := proto.decode_bot_create(sent[0].body)
		_, _, key2, _, _ := proto.decode_bot_create(sent[1].body)
		testing.expect_value(t, key1, public_of(t, first))
		testing.expect_value(t, key2, public_of(t, c.auth.bot_token))
		testing.expect(t, key1 != key2)
	}
}

@(test)
test_another_token_for_a_bot :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	defer auth_bot_token_forget(&tc.c)
	c := &tc.c

	auth_bot_token(c, 42)
	req, ok := tc_one(t, &tc, .Bot_Token_Add)
	testing.expect(t, ok)
	account, key, device, dec := proto.decode_bot_token_add(req.body)
	testing.expect(t, dec)
	testing.expect_value(t, account, proto.Account_Id(42))
	testing.expect_value(t, device, BOT_TOKEN_DEVICE)
	token := strings.clone(c.auth.bot_token)
	defer delete(token)
	testing.expect_value(t, key, public_of(t, token))

	tc_answer(&tc, req.id, .Ok)
	testing.expect_value(t, v.bot_token, token)
	testing.expect_value(t, v.bot_token_account, proto.Account_Id(42))
	testing.expect_value(t, c.auth.bot_token, "")
	testing.expect_value(
		t,
		v.notice.text,
		"Token created. Copy it now, because it will not be shown again.",
	)
	// The bot's devices are listed again, to show the new one.
	list, listed := tc_one(t, &tc, .Device_List)
	testing.expect(t, listed)
	who, who_ok := proto.decode_account_id(list.body)
	testing.expect(t, who_ok)
	testing.expect_value(t, who, proto.Account_Id(42))
}

@(test)
test_token_refused :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	c := &tc.c
	auth_bot_token(c, 42)
	req, _ := tc_one(t, &tc, .Bot_Token_Add)
	tc_answer(&tc, req.id, .Denied)
	testing.expect_value(t, c.auth.bot_token, "")
	testing.expect_value(t, v.bot_token, "")
	testing.expect_value(t, v.notice.text, status_text(.Denied, "account"))
	testing.expect_value(t, len(tc_sent(t, &tc)), 0) // no device list for a token that wasn't made
}

@(test)
test_token_is_logged_without_a_ui :: proc(t: ^testing.T) {
	tc: Test_Conn
	_ = open_bots(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.view = nil
	auth_bot_token(c, 42)
	req, _ := tc_one(t, &tc, .Bot_Token_Add)
	tc_answer(&tc, req.id, .Ok)
	// Shown (logged) once, and not kept.
	testing.expect_value(t, c.auth.bot_token, "")
}

@(test)
test_devices_of_another_account :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_bots(&tc)
	defer tc_close(&tc)
	defer view_clear_other_devices(v)
	c := &tc.c
	publish_other_devices(
		c,
		42,
		{
			{
				key = {0 = 1},
				name = "API token",
				agent = "bot",
				created = 100,
				last_seen = 200,
				flags = {.Online},
			},
			{key = {0 = 2}, name = "old", created = 50},
		},
	)
	testing.expect_value(t, v.other_devices_of, proto.Account_Id(42))
	testing.expect_value(t, len(v.other_devices), 2)
	testing.expect_value(t, v.other_devices_count, 1)
	if len(v.other_devices) == 2 {
		testing.expect_value(t, v.other_devices[0].name, "API token")
		testing.expect(t, .Online in v.other_devices[0].flags)
		testing.expect_value(t, v.other_devices[1].last_seen, u64(0))
	}
	// A new list replaces the old one.
	publish_other_devices(c, 43, {{key = {0 = 3}, name = "x"}})
	testing.expect_value(t, v.other_devices_of, proto.Account_Id(43))
	testing.expect_value(t, len(v.other_devices), 1)
	testing.expect_value(t, v.other_devices_count, 2)
}
