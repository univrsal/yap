package server

import "core:testing"

import "common:proto"

// ts_commands_set registers commands as a connection.
ts_commands_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	list: []proto.Bot_Command,
) -> proto.Status {
	buf: [proto.BOT_COMMANDS_MAX_SIZE]u8
	body := proto.encode_bot_commands(buf[:], list)
	testing.expect(t, body != nil)
	status, _ := ts_ask(t, ts, u, .Bot_Commands_Set, body)
	return status
}

// ts_commands_changed returns the Commands_Changed events in `events`.
ts_commands_changed :: proc(
	t: ^testing.T,
	events: []Test_Event,
) -> (
	accounts: [dynamic]proto.Account_Id,
	lists: [dynamic][]proto.Bot_Command,
) {
	accounts = make([dynamic]proto.Account_Id, context.temp_allocator)
	lists = make([dynamic][]proto.Bot_Command, context.temp_allocator)
	for e in events {
		if e.op != .Commands_Changed {
			continue
		}
		account, list, ok := proto.decode_bot_commands(e.body, true)
		testing.expect(t, ok)
		append(&accounts, account)
		append(&lists, list)
	}
	return
}

@(test)
test_bot_commands_set :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	alice := logged_in(t, &ts, "alice")

	buf: [proto.BOT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "weather", "", ts_bot_key(1), ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	bot_id, _ := proto.decode_account_id(body)
	bot := ts_connect(&ts, ts_bot_key(1))
	ts_events(t, &ts, admin)
	ts_events(t, &ts, alice)

	// Only bots may register commands, and a bad set is refused.
	weather := []proto.Bot_Command{{"weather", "Show the weather", "<city>"}, {"ping", "", ""}}
	testing.expect_value(t, ts_commands_set(t, &ts, alice, weather), proto.Status.Denied)
	status, _ = ts_ask(t, &ts, bot, .Bot_Commands_Set, []u8{1, 3, 'B', 'a', 'd', 0, 0})
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(t, &ts, bot, .Bot_Commands_Set, nil)
	testing.expect_value(t, status, proto.Status.Invalid)
	testing.expect_value(t, len(ts_events(t, &ts, alice)), 0)

	// Everyone is told what the bot registered.
	testing.expect_value(t, ts_commands_set(t, &ts, bot, weather), proto.Status.Ok)
	for u in ([]^Conn{alice, admin, bot}) {
		accounts, lists := ts_commands_changed(t, ts_events(t, &ts, u))
		testing.expect_value(t, len(accounts), 1)
		testing.expect_value(t, accounts[0], bot_id)
		testing.expect_value(t, len(lists[0]), 2)
		testing.expect_value(t, lists[0][0], weather[0])
		testing.expect_value(t, lists[0][1], weather[1])
	}

	// A new set replaces the old one.
	roll := []proto.Bot_Command{{"roll", "Roll dice", ""}}
	testing.expect_value(t, ts_commands_set(t, &ts, bot, roll), proto.Status.Ok)
	accounts, lists := ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(accounts), 1)
	testing.expect_value(t, len(lists[0]), 1)
	testing.expect_value(t, lists[0][0], roll[0])

	// Someone who logs in is told in the sync, and only about bots that have
	// commands.
	late := ts_connect(&ts)
	status, _ = ts_login(t, &ts, late, "alice", "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	accounts, lists = ts_commands_changed(t, ts_events(t, &ts, late))
	testing.expect_value(t, len(accounts), 1)
	testing.expect_value(t, accounts[0], bot_id)
	testing.expect_value(t, lists[0][0], roll[0])

	// The commands go when the bot does.
	ts_disconnect(&ts, bot)
	accounts, lists = ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(accounts), 1)
	testing.expect_value(t, accounts[0], bot_id)
	testing.expect_value(t, len(lists[0]), 0)
	ts_events(t, &ts, late)
	ts_disconnect(&ts, late)
	late = ts_connect(&ts)
	status, _ = ts_login(t, &ts, late, "alice", "a password")
	_, lists = ts_commands_changed(t, ts_events(t, &ts, late))
	testing.expect_value(t, len(lists), 0)
}

@(test)
test_bot_commands_connections :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	alice := logged_in(t, &ts, "alice")
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
	status, _ = ts_ask(t, &ts, admin, .Bot_Token_Add, proto.encode_bot_token_add(buf[:], id, ts_bot_key(2), ""))
	testing.expect_value(t, status, proto.Status.Ok)
	one := ts_connect(&ts, ts_bot_key(1))
	two := ts_connect(&ts, ts_bot_key(2))
	ts_events(t, &ts, alice)

	// The newest set counts, and when its connection goes the older one
	// counts again. A connection that never registered changes nothing.
	a := []proto.Bot_Command{{"first", "", ""}}
	b := []proto.Bot_Command{{"second", "", ""}}
	testing.expect_value(t, ts_commands_set(t, &ts, one, a), proto.Status.Ok)
	testing.expect_value(t, ts_commands_set(t, &ts, two, b), proto.Status.Ok)
	_, lists := ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(lists), 2)
	testing.expect_value(t, lists[1][0].name, "second")

	ts_disconnect(&ts, two)
	_, lists = ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, len(lists[0]), 1)
	testing.expect_value(t, lists[0][0].name, "first")

	// Logging out, such as when the bot is disabled, ends them too.
	disable_buf: [5]u8
	status, _ = ts_ask(t, &ts, admin, .Account_Disable, proto.encode_account_disable(&disable_buf, id, true))
	testing.expect_value(t, status, proto.Status.Ok)
	_, lists = ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, len(lists[0]), 0)
}
