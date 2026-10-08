#+build !wasi
package conn

import "core:fmt"
import "core:testing"

import "common:proto"

@(test)
test_mentions_transform :: proc(t: ^testing.T) {
	accounts: map[proto.Account_Id]Dir_Account
	defer delete(accounts)
	accounts[17] = {
		username = "alice",
		display  = "Alice A.",
	}
	accounts[4] = {
		username = "bob",
		display  = "Bob",
	}
	accounts[5] = {
		username = "bob.b",
		display  = "Other Bob",
	}

	// Typed to stored: at word starts, the longest username, a full stop
	// left alone, emails left alone.
	testing.expect_value(t, mentions_encode("@alice hi", accounts, nil), "<@17> hi")
	testing.expect_value(t, mentions_encode("hi @Alice.", accounts, nil), "hi <@17>.")
	testing.expect_value(t, mentions_encode("@bob.b and @bob.", accounts, nil), "<@5> and <@4>.")
	testing.expect_value(t, mentions_encode("@alice@bob", accounts, nil), "<@17>@bob")
	testing.expect_value(
		t,
		mentions_encode("mail me@alice.com", accounts, nil),
		"mail me@alice.com",
	)
	testing.expect_value(
		t,
		mentions_encode("@nobody @ @everyone", accounts, nil),
		"@nobody @ <@everyone>",
	)
	testing.expect_value(t, mentions_encode("no mentions", accounts, nil), "no mentions")

	// And back, for editing.
	testing.expect_value(
		t,
		mentions_for_edit("<@17>, <@5><@4> <@everyone> <@99> <@x>", accounts, nil),
		"@alice, @bob.b@bob @everyone <@99> <@x>",
	)
	round := "@alice and @bob.b, @everyone"
	testing.expect_value(
		t,
		mentions_for_edit(mentions_encode(round, accounts, nil), accounts, nil),
		round,
	)

	// Shown: names as they are now, a span each.
	shown, spans := mentions_display("<@17>hi <@99> <@4><@everyone> <@x>", accounts, nil, 4)
	testing.expect_value(t, shown, "@Alice A.hi @unknown @Bob@everyone <@x>")
	testing.expect_value(t, len(spans), 4)
	if len(spans) == 4 {
		testing.expect_value(t, spans[0], Mention_Span{0, 9, false})
		testing.expect_value(t, shown[spans[1].start:spans[1].end], "@unknown")
		testing.expect_value(t, spans[2], Mention_Span{21, 25, true})
		testing.expect(t, spans[3].me, "everyone isn't the reader")
	}
	plain, none := mentions_display("plain", accounts, nil, 4)
	testing.expect_value(t, plain, "plain")
	testing.expect_value(t, len(none), 0)
}

@(test)
test_role_mentions_transform :: proc(t: ^testing.T) {
	accounts: map[proto.Account_Id]Dir_Account
	defer delete(accounts)
	accounts[17] = {
		username = "alice",
		display  = "Alice A.",
		roles    = {5},
	}
	accounts[4] = {
		username = "dev",
		display  = "Dev Person",
	}
	roles := []View_Role {
		{id = proto.EVERYONE_ROLE, name = "everyone", flags = {.Mentionable}},
		{id = 5, name = "Team Leads", flags = {.Mentionable}},
		{id = 6, name = "Team", flags = {.Mentionable}},
		{id = 7, name = "dev", flags = {.Mentionable}},
		{id = 8, name = "quiet"},
	}

	// Typed to stored: the name with its spaces, whatever its case; the
	// longest; not inside a word; only one that can be mentioned; an
	// account's username over a role's name the same.
	testing.expect_value(t, mentions_encode("@team leads, look", accounts, roles), "<@&5>, look")
	testing.expect_value(t, mentions_encode("@Team leader", accounts, roles), "<@&6> leader")
	testing.expect_value(t, mentions_encode("@Teamwork @Team", accounts, roles), "@Teamwork <@&6>")
	testing.expect_value(t, mentions_encode("@quiet @dev", accounts, roles), "@quiet <@4>")
	testing.expect_value(t, mentions_encode("@everyone", accounts, roles), "<@everyone>")

	// And back: a role whose name is a username stays its token.
	testing.expect_value(
		t,
		mentions_for_edit("<@&5> <@&7> <@&99>", accounts, roles),
		"@Team Leads <@&7> <@&99>",
	)
	round := "@Team Leads and @Team"
	testing.expect_value(
		t,
		mentions_for_edit(mentions_encode(round, accounts, roles), accounts, roles),
		round,
	)

	// Shown: its name, and the reader's if the reader has it.
	shown, spans := mentions_display("<@&5> <@&6> <@&99>", accounts, roles, 17)
	testing.expect_value(t, shown, "@Team Leads @Team @unknown role")
	testing.expect_value(t, len(spans), 3)
	if len(spans) == 3 {
		testing.expect_value(t, spans[0], Mention_Span{0, 11, true})
		testing.expect(t, !spans[1].me, "alice hasn't got the role")
	}
}

@(test)
test_emoji_transform :: proc(t: ^testing.T) {
	custom := []string{"party", "smile"}
	// Shortcodes become characters, but not the server's own names, nor
	// what isn't a shortcode.
	testing.expect_value(t, emoji_encode("hi :+1: :grinning:", custom), "hi 👍 😀")
	testing.expect_value(
		t,
		emoji_encode(":smile: :party: :nope: a:b", custom),
		":smile: :party: :nope: a:b",
	)
	testing.expect_value(t, emoji_encode("::grinning:", custom), ":😀")

	// Shown: the server's own as placeholders, with which they are.
	accounts: map[proto.Account_Id]Dir_Account
	defer delete(accounts)
	shown, _, icons := text_display(":party::smile: x :nope: <@1>", accounts, nil, 0, custom)
	ph := proto.CUSTOM_EMOJI_PLACEHOLDER
	testing.expect_value(t, shown, fmt.tprintf("%r%r x :nope: @unknown", ph, ph))
	testing.expect_value(t, len(icons), 2)
	if len(icons) == 2 {
		testing.expect_value(t, icons[0], Emoji_Span{0, 3, 0})
		testing.expect_value(t, icons[1], Emoji_Span{3, 6, 1})
	}
	plain, _, none := text_display("no :emoji: here", accounts, nil, 0, nil)
	testing.expect_value(t, plain, "no :emoji: here")
	testing.expect_value(t, len(none), 0)
}
