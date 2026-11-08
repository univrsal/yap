#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

@(private = "file")
changed :: proc(c: ^Server_Conn, account: proto.Account_Id, list: []proto.Bot_Command) {
	buf: [proto.COMMANDS_CHANGED_MAX_SIZE]u8
	body := proto.encode_bot_commands(buf[:], list, account)
	assert(body != nil)
	assert(bot_commands_event(c, .Commands_Changed, body))
}

@(private = "file")
names :: proc(list: []Bot_Command_Entry) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for e in list {
		append(&out, e.bot)
		append(&out, ":")
		append(&out, e.name)
		append(&out, " ")
	}
	return strings.concatenate(out[:], context.temp_allocator)
}

@(private = "file")
two_bots :: proc(c: ^Server_Conn) {
	c.auth.accounts[7] = {
		username = strings.clone("dicebot"),
	}
	c.auth.accounts[9] = {
		username = strings.clone("coinbot"),
	}
	changed(c, 7, {{"roll", "Roll dice", "<n>d<s>"}, {"ping", "", ""}})
	changed(c, 9, {{"flip", "Flip a coin", ""}, {"roll", "Roll a coin", ""}})
}

@(private = "file")
accounts_free :: proc(c: ^Server_Conn) {
	for _, a in c.auth.accounts {
		delete(a.username)
	}
	delete(c.auth.accounts)
}

@(test)
test_bot_commands_events :: proc(t: ^testing.T) {
	c: Server_Conn
	defer bot_commands_destroy(&c)
	defer accounts_free(&c)
	two_bots(&c)

	// Sorted by name, then by bot.
	list := c.bot_commands.entries[:]
	testing.expect_value(t, names(list), "coinbot:flip dicebot:ping coinbot:roll dicebot:roll ")
	testing.expect_value(t, list[3].description, "Roll dice")
	testing.expect_value(t, list[3].usage, "<n>d<s>")
	testing.expect_value(t, list[3].account, proto.Account_Id(7))

	// A new set replaces the bot's old one and leaves the others alone.
	changed(&c, 7, {{"roll", "Roll again", ""}})
	testing.expect_value(
		t,
		names(c.bot_commands.entries[:]),
		"coinbot:flip coinbot:roll dicebot:roll ",
	)
	testing.expect_value(t, c.bot_commands.entries[2].description, "Roll again")

	// An empty set removes them, a body that isn't one changes nothing.
	changed(&c, 9, nil)
	testing.expect_value(t, names(c.bot_commands.entries[:]), "dicebot:roll ")
	testing.expect(t, bot_commands_event(&c, .Commands_Changed, {1, 2}))
	testing.expect_value(t, len(c.bot_commands.entries), 1)

	// Other events aren't ours; the one for bots is ignored.
	testing.expect(t, !bot_commands_event(&c, .Msg_New, nil))
	testing.expect(t, bot_commands_event(&c, .Command_Invoked, nil))

	// A login sync starts from nothing.
	bot_commands_begin(&c)
	testing.expect_value(t, len(c.bot_commands.entries), 0)
}

@(test)
test_bot_commands_view :: proc(t: ^testing.T) {
	c: Server_Conn
	defer bot_commands_destroy(&c)
	defer accounts_free(&c)
	two_bots(&c)
	v: View
	defer {
		view_clear_bot_commands(&v)
		delete(v.bot_commands)
	}
	c.view = &v
	changed(&c, 9, {{"flip", "Flip a coin", ""}})
	testing.expect_value(t, names(v.bot_commands[:]), "coinbot:flip dicebot:ping dicebot:roll ")
	// The view has copies.
	testing.expect(t, raw_data(v.bot_commands[0].name) != raw_data(c.bot_commands.entries[0].name))
	c.view = nil
}

@(test)
test_bot_commands_lookup :: proc(t: ^testing.T) {
	c: Server_Conn
	defer bot_commands_destroy(&c)
	defer accounts_free(&c)
	two_bots(&c)
	list := c.bot_commands.entries[:]

	// A name that two bots have means both; naming the bot picks one.
	testing.expect_value(t, names(bot_commands_lookup(list, "roll")), "coinbot:roll dicebot:roll ")
	testing.expect_value(t, names(bot_commands_lookup(list, "ROLL")), "coinbot:roll dicebot:roll ")
	testing.expect_value(t, names(bot_commands_lookup(list, "dicebot:roll")), "dicebot:roll ")
	testing.expect_value(t, names(bot_commands_lookup(list, "DiceBot:Roll")), "dicebot:roll ")
	testing.expect_value(t, names(bot_commands_lookup(list, "flip")), "coinbot:flip ")
	testing.expect_value(t, names(bot_commands_lookup(list, "dicebot:flip")), "")
	testing.expect_value(t, names(bot_commands_lookup(list, "nope")), "")
	testing.expect_value(t, names(bot_commands_lookup(list, ":roll")), "")
	testing.expect_value(t, names(bot_commands_lookup(list, "")), "")

	// Which need the bot's name to be typed.
	testing.expect(t, bot_command_ambiguous(list, list[2]))
	testing.expect(t, !bot_command_ambiguous(list, list[0]))
	testing.expect_value(t, bot_command_typed(list[3]), "dicebot:roll")

	// A DM has the one bot, a group its bots, a channel any.
	testing.expect_value(
		t,
		names(bot_commands_scope(list, {7}, true)),
		"dicebot:ping dicebot:roll ",
	)
	testing.expect_value(
		t,
		names(bot_commands_scope(list, {9, 4}, true)),
		"coinbot:flip coinbot:roll ",
	)
	testing.expect_value(t, names(bot_commands_scope(list, {4}, true)), "")
	testing.expect_value(t, len(bot_commands_scope(list, nil, false)), 4)
}

@(test)
test_view_bot_commands :: proc(t: ^testing.T) {
	c: Server_Conn
	defer bot_commands_destroy(&c)
	defer accounts_free(&c)
	two_bots(&c)
	v: View
	defer {
		view_clear_bot_commands(&v)
		delete(v.bot_commands)
		delete(v.dms)
	}
	c.view = &v
	changed(&c, 9, {{"flip", "", ""}, {"roll", "", ""}})
	c.view = nil
	dm := View_DM {
		id   = 20,
		with = 7,
	}
	group := View_DM {
		id    = 21,
		count = 2,
	}
	group.members[0], group.members[1] = 4, 9
	append(&v.dms, dm, group)

	testing.expect_value(t, names(view_bot_commands(&v, 20)), "dicebot:ping dicebot:roll ")
	testing.expect_value(t, names(view_bot_commands(&v, 21)), "coinbot:flip coinbot:roll ")
	// A channel, or a conversation we know nothing about.
	testing.expect_value(t, len(view_bot_commands(&v, 1)), 4)
	testing.expect_value(t, len(view_bot_commands(&v, 99)), 4)
}

@(test)
test_command_line_split :: proc(t: ^testing.T) {
	word, args, ok := command_line_split("  /Roll   2d6 + 1 ")
	testing.expect(t, ok)
	testing.expect_value(t, word, "roll")
	testing.expect_value(t, args, "2d6 + 1")
	word, args, ok = command_line_split("/dicebot:roll")
	testing.expect(t, ok)
	testing.expect_value(t, word, "dicebot:roll")
	testing.expect_value(t, args, "")
	word, args, ok = command_line_split("/ roll")
	testing.expect(t, ok)
	testing.expect_value(t, word, "")
	for not_a_command in ([]string{"", "roll", "/", "  "}) {
		_, _, ok = command_line_split(not_a_command)
		testing.expectf(t, !ok, "%q", not_a_command)
	}
}
