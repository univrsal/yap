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
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], id, ts_bot_key(2), ""),
	)
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
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Account_Disable,
		proto.encode_account_disable(&disable_buf, id, true),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	_, lists = ts_commands_changed(t, ts_events(t, &ts, alice))
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, len(lists[0]), 0)
}

// ts_command_run asks to run a command as `u`.
ts_command_run :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	req: proto.Command_Run_Request,
) -> proto.Status {
	buf: [proto.COMMAND_RUN_MAX_SIZE]u8
	body := proto.encode_command_run(buf[:], req)
	testing.expect(t, body != nil)
	status, _ := ts_ask(t, ts, u, .Command_Run, body)
	return status
}

// ts_invoked returns the Command_Invoked events in `events`.
ts_invoked :: proc(t: ^testing.T, events: []Test_Event) -> [dynamic]proto.Command_Invoked_Event {
	out := make([dynamic]proto.Command_Invoked_Event, context.temp_allocator)
	for e in events {
		if e.op != .Command_Invoked {
			continue
		}
		ev, ok := proto.decode_command_invoked(e.body)
		testing.expect(t, ok)
		append(&out, ev)
	}
	return out
}

@(test)
test_command_run :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "admin", "admin's password", {.Owner})
	alice_acc := ts_account(t, &ts, "alice", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	admin := ts_connect(&ts)
	status, _ := ts_login(t, &ts, admin, "admin", "admin's password")
	testing.expect_value(t, status, proto.Status.Ok)
	alice := logged_in(t, &ts, "alice")
	carol := logged_in(t, &ts, "carol")

	buf: [proto.BOT_BODY_MAX]u8
	body: []u8
	status, body = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Create,
		proto.encode_bot_create(buf[:], "dicebot", "", ts_bot_key(1), ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	bot_id, _ := proto.decode_account_id(body)
	bot := ts_connect(&ts, ts_bot_key(1))
	roll := []proto.Bot_Command{{"roll", "Roll dice", "<n>d<s>"}}
	testing.expect_value(t, ts_commands_set(t, &ts, bot, roll), proto.Status.Ok)
	home := ts.s.convs.home.id
	ts_events(t, &ts, bot)
	ts_events(t, &ts, alice)

	// The bot is told who ran what, where, and nothing is posted.
	req := proto.Command_Run_Request {
		conv    = home,
		account = bot_id,
		name    = "roll",
		args    = "  2d6 ",
	}
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Ok)
	got := ts_invoked(t, ts_events(t, &ts, bot))
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0].conv, home)
	testing.expect_value(t, got[0].invoker, alice_acc.id)
	testing.expect_value(t, got[0].name, "roll")
	testing.expect_value(t, got[0].args, "2d6")
	testing.expect_value(t, got[0].thread_root, proto.Msg_Id(0))
	testing.expect(t, got[0].id != 0)
	events := ts_events(t, &ts, alice)
	_, posted := has_event(events, .Msg_New)
	testing.expect(t, !posted)
	_, told := has_event(events, .Command_Invoked)
	testing.expect(t, !told)

	// Every run has its own number.
	testing.expect_value(t, ts_command_run(t, &ts, carol, req), proto.Status.Ok)
	again := ts_invoked(t, ts_events(t, &ts, bot))
	testing.expect_value(t, len(again), 1)
	testing.expect(t, again[0].id != got[0].id)
	testing.expect_value(t, again[0].invoker, carol_acc.id)

	// In a DM with the bot.
	status_dm, dm := dm_open_as(t, &ts, alice, bot_id)
	testing.expect_value(t, status_dm, proto.Status.Ok)
	dm_req := req
	dm_req.conv = dm
	testing.expect_value(t, ts_command_run(t, &ts, alice, dm_req), proto.Status.Ok)
	got = ts_invoked(t, ts_events(t, &ts, bot))
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0].conv, dm)

	// A command the bot doesn't have, an account that isn't a bot, or
	// doesn't exist.
	other := req
	other.name = "nope"
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Not_Found)
	other = req
	other.account = carol_acc.id
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Not_Found)
	other.account = 999
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Not_Found)

	// A conversation that doesn't exist, or that the invoker can't see (a DM
	// of two others), or isn't a member of.
	other = req
	other.conv = 4000
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Not_Found)
	_, carol_dm := dm_open_as(t, &ts, carol, alice_acc.id)
	_, admin_dm := dm_open_as(t, &ts, admin, carol_acc.id)
	other.conv = admin_dm
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Not_Found)

	// The bot isn't in a DM of two people, so it couldn't answer there.
	other.conv = carol_dm
	testing.expect_value(t, ts_command_run(t, &ts, alice, other), proto.Status.Denied)

	// Someone who can't write somewhere can't make a bot write there.
	ok := conv_rights_set(&ts.s.convs, ts.s.convs.home, {{proto.EVERYONE_ROLE, {.See}}})
	testing.expect(t, ok)
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Denied)
	ok = conv_rights_set(
		&ts.s.convs,
		ts.s.convs.home,
		{{proto.EVERYONE_ROLE, proto.CONV_RIGHTS_ALL}},
	)
	testing.expect(t, ok)
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Ok)
	ts_events(t, &ts, bot)

	alice.command_runs = {} // the burst was used up by now
	// A bad body.
	status, _ = ts_ask(t, &ts, alice, .Command_Run, []u8{1, 2, 3})
	testing.expect_value(t, status, proto.Status.Invalid)

	// Once the bot is gone nothing can be run.
	ts_disconnect(&ts, bot)
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Not_Found)
}

@(test)
test_command_run_threads :: proc(t: ^testing.T) {
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
		proto.encode_bot_create(buf[:], "dicebot", "", ts_bot_key(1), ""),
	)
	bot_id, _ := proto.decode_account_id(body)
	bot := ts_connect(&ts, ts_bot_key(1))
	testing.expect_value(t, ts_commands_set(t, &ts, bot, {{"roll", "", ""}}), proto.Status.Ok)
	home := ts.s.convs.home.id

	post := proto.Msg_Post {
		conv  = home,
		nonce = 1,
		kind  = .Text,
		text  = "root",
	}
	post_buf: [256]u8
	status, body = ts_ask(t, &ts, alice, .Msg_Post, proto.encode_msg_post(post_buf[:], post))
	testing.expect_value(t, status, proto.Status.Ok)
	root, _, posted := proto.decode_msg_posted(body)
	testing.expect(t, posted)
	post.nonce, post.thread_root, post.text = 2, root, "reply"
	status, body = ts_ask(t, &ts, alice, .Msg_Post, proto.encode_msg_post(post_buf[:], post))
	testing.expect_value(t, status, proto.Status.Ok)
	reply, _, _ := proto.decode_msg_posted(body)
	ts_events(t, &ts, bot)

	// The thread of a message, also if it is a reply, is its root.
	req := proto.Command_Run_Request {
		conv        = home,
		thread_root = reply,
		account     = bot_id,
		name        = "roll",
	}
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Ok)
	got := ts_invoked(t, ts_events(t, &ts, bot))
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0].thread_root, root)

	// A thread that isn't one is refused.
	req.thread_root = 99_999
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Invalid)
}

@(test)
test_command_run_routing :: proc(t: ^testing.T) {
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
		proto.encode_bot_create(buf[:], "dicebot", "", ts_bot_key(1), ""),
	)
	bot_id, _ := proto.decode_account_id(body)
	status, _ = ts_ask(
		t,
		&ts,
		admin,
		.Bot_Token_Add,
		proto.encode_bot_token_add(buf[:], bot_id, ts_bot_key(2), ""),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	old := ts_connect(&ts, ts_bot_key(1))
	new := ts_connect(&ts, ts_bot_key(2))
	testing.expect_value(t, ts_commands_set(t, &ts, old, {{"roll", "", ""}}), proto.Status.Ok)
	testing.expect_value(t, ts_commands_set(t, &ts, new, {{"flip", "", ""}}), proto.Status.Ok)
	ts_events(t, &ts, old)
	ts_events(t, &ts, new)

	// Only the connection whose commands count is told, and "roll" is not
	// one of the commands that count.
	req := proto.Command_Run_Request {
		conv    = ts.s.convs.home.id,
		account = bot_id,
		name    = "roll",
	}
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Not_Found)
	req.name = "flip"
	testing.expect_value(t, ts_command_run(t, &ts, alice, req), proto.Status.Ok)
	testing.expect_value(t, len(ts_invoked(t, ts_events(t, &ts, old))), 0)
	testing.expect_value(t, len(ts_invoked(t, ts_events(t, &ts, new))), 1)

	// Running commands is limited: a burst, then a few a second.
	alice.command_runs = {}
	limited := 0
	for _ in 0 ..< COMMAND_BURST + 5 {
		if ts_command_run(t, &ts, alice, req) == .Rate_Limited {
			limited += 1
		}
	}
	testing.expect(t, limited >= 4 && limited <= 5, "limited")
}
