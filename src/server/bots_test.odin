package server

import "core:testing"

import "common:proto"

// ts_bot_key returns a token's public key for a test. Any 32 bytes work
// because the test's connections never perform a handshake.
ts_bot_key :: proc(n: u8) -> (key: [proto.KEY_SIZE]u8) {
	key[0], key[1] = 0xb0, n
	return
}

@(test)
test_bot_create :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "alice's password")
	admin := ts_connect(&ts)
	alice := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, alice, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	ts_events(t, &ts, admin)

	buf: [proto.BOT_BODY_MAX]u8
	key := ts_bot_key(1)
	// Only accounts that can manage accounts may create bots.
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "weather", "Weather", key, ""),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	// Creating a bot fails without a key or with a name that's taken.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "weather", "Weather", {}, ""),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "Alice", "Weather", key, ""),
	)
	testing.expect_value(t, status, proto.Status.Conflict)

	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "Weather", "The weather", key, ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, ok := proto.decode_account_id(body)
	testing.expect(t, ok)
	bot := account_by_id(&ts.s.accounts, id)
	testing.expect(t, bot != nil)
	testing.expect_value(t, bot.username, "weather")
	testing.expect_value(t, bot.display, "The weather")
	testing.expect_value(t, bot.flags, proto.Account_Flags{.Bot})
	// Everyone is told about the new bot, including its flag.
	e, told := has_event(ts_events(t, &ts, admin), .Account_Changed)
	testing.expect(t, told)
	record, decoded := proto.decode_account(e.body)
	testing.expect(t, decoded)
	testing.expect_value(t, record.flags, proto.Account_Flags{.Bot})

	// The key is already a device, so another bot can't use it.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "other", "", key, ""),
	)
	testing.expect_value(t, status, proto.Status.Conflict)

	// The bot's token alone is enough to log it in.
	conn := ts_connect(&ts, key)
	testing.expect(t, conn.account == bot)
	d := device_of(&ts.s.accounts, key)
	testing.expect(t, d != nil)
	testing.expect_value(t, d.name, proto.BOT_DEVICE_NAME)
}

@(test)
test_bot_limits :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "alice's password")
	admin := ts_connect(&ts)
	alice := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, alice, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	buf: [proto.BOT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "helper", "", ts_bot_key(1), ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _ := proto.decode_account_id(body)
	bot := ts_connect(&ts, ts_bot_key(1))
	testing.expect(t, bot.account != nil && bot.account.id == id)

	// No password logs in as the bot, not even an empty one.
	stranger := ts_connect(&ts)
	for password in ([]string{"", "a password"}) {
		status, _ = ts_login(t, &ts, stranger, "helper", password)
		testing.expect_value(t, status, proto.Status.Wrong_Password)
	}
	// A bot has no password to change, an admin can't set one, and the
	// bot can't delete itself because it can't prove it knows a password.
	status, _ = ts_ask(
		t,
		&ts,
		bot,
		.Password_Change,
		proto.encode_password_change(buf[:], "", "a new password", false),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Password_Set,
		proto.encode_account_password_set(buf[:], id, "a new password"),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(t, &ts, bot, .Account_Delete, proto.encode_account_delete(buf[:], id, ""))
	testing.expect_value(t, status, proto.Status.Denied)

	// Bots can't use voice. They can't join a room or take part in a call,
	// either as caller or as callee.
	room_buf: [4]u8
	home := proto.Room(ts.s.convs.home.id)
	status, _ = ts_ask(t, &ts, bot, .Voice_Join, proto.encode_room(&room_buf, home))
	testing.expect_value(t, status, proto.Status.Denied)
	testing.expect_value(t, bot.room, proto.Room(0))
	id_buf: [4]u8
	status, _ = ts_ask(
		t,
		&ts,
		bot,
		.Call_Start,
		proto.encode_account_id(&id_buf, alice.account.id),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(t, &ts, alice, .Call_Start, proto.encode_account_id(&id_buf, id))
	testing.expect_value(t, status, proto.Status.Denied)

	// Messaging works for bots like for any other account.
	dm_buf: [4]u8
	status, _ = ts_ask(t, &ts, alice, .DM_Open, proto.encode_account_id(&dm_buf, id))
	testing.expect_value(t, status, proto.Status.Ok)
}

@(test)
test_bot_tokens :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "alice's password")
	admin := ts_connect(&ts)
	alice := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_login(t, &ts, alice, "alice", "alice's password")
	testing.expect_value(t, status, proto.Status.Ok)
	buf: [proto.BOT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "helper", "", ts_bot_key(1), "laptop"),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	id, _ := proto.decode_account_id(body)

	// Add another token for another place where the bot runs.
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], id, ts_bot_key(2), "server"),
	)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], id, ts_bot_key(2), "server"),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	// The same token can't be added twice, and tokens can only be added
	// to a bot.
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], id, ts_bot_key(2), "again"),
	)
	testing.expect_value(t, status, proto.Status.Conflict)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], alice.account.id, ts_bot_key(3), ""),
	)
	testing.expect_value(t, status, proto.Status.Not_Found)

	first := ts_connect(&ts, ts_bot_key(1))
	second := ts_connect(&ts, ts_bot_key(2))
	testing.expect(t, first.account != nil && first.account.id == id)
	testing.expect(t, second.account == first.account)

	// The admin can see the bot's tokens, nobody else can.
	id_buf: [4]u8
	status, body = ts_ask(t, &ts, admin, .Device_List, proto.encode_account_id(&id_buf, id))
	testing.expect_value(t, status, proto.Status.Ok)
	devices_buf: [8]proto.Device
	devices, ok := proto.decode_devices(body, devices_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 2)
	for d in devices {
		testing.expect_value(t, d.flags, proto.Device_Flags{.Online})
		switch d.key {
		case ts_bot_key(1):
			testing.expect_value(t, d.name, "laptop")
		case ts_bot_key(2):
			testing.expect_value(t, d.name, "server")
		case:
			testing.fail(t)
		}
	}
	status, _ = ts_ask(t, &ts, alice, .Device_List, proto.encode_account_id(&id_buf, id))
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(t, &ts, alice, .Device_List, proto.encode_account_id(&id_buf, 999))
	testing.expect_value(t, status, proto.Status.Not_Found)
	// Asking for one's own devices by id is the same as asking without an id.
	status, body = ts_ask(
		t,
		&ts,
		alice,
		.Device_List,
		proto.encode_account_id(&id_buf, alice.account.id),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	devices, ok = proto.decode_devices(body, devices_buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(devices), 1)

	// Revoking one token logs that connection out and leaves the other.
	revoke_buf: [proto.ACCOUNT_BODY_MAX]u8
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Device_Revoke,
		proto.encode_device_revoke(revoke_buf[:], ts_bot_key(1)),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, first.account == nil)
	testing.expect(t, second.account != nil)
	e, told := has_event(ts_events(t, &ts, first), .Logged_Out)
	testing.expect(t, told)
	testing.expect_value(t, e.body[0], u8(proto.Logout_Reason.Revoked))
}
