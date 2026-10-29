package mattermost

import "core:mem/virtual"
import "core:testing"

// The rules for the text of a message, from the sample's own posts and from the
// cases that make a rule go wrong.

@(private = "file")
rewriter_for_test :: proc(a: ^virtual.Arena) -> Rewriter {
	_ = virtual.arena_init_growing(a)
	al := virtual.arena_allocator(a)
	emoji := new(Emoji_Map, al)
	emoji^ = emoji_map_make(al)
	emoji_add_custom(emoji, "partyparrot", "partyparrot")
	emoji_add_custom(emoji, "Party-Time", "party_time")
	r := Rewriter {
		users    = make(map[string]u32, al),
		channels = make(map[string]string, al),
		emoji    = emoji,
	}
	r.users["bob"] = 3
	r.users["carol"] = 4
	r.users["alice"] = 5
	r.users["bob.smith"] = 6
	r.channels["secret"] = "Secret"
	r.channels["general-talk"] = "General Talk Renamed"
	r.channels["off-topic"] = "Off-Topic"
	return r
}

@(test)
test_rewrite_text :: proc(t: ^testing.T) {
	arena: virtual.Arena
	r := rewriter_for_test(&arena)
	defer virtual.arena_destroy(&arena)

	Case :: struct {
		in_, want: string,
	}
	cases := []Case {
		// The sample's.
		{"Pizza it is, thanks @bob", "Pizza it is, thanks <@3>"},
		{"@here quick one: standup moved to 10:00", "<@here> quick one: standup moved to 10:00"},
		{"@all please update your profiles", "<@everyone> please update your profiles"},
		{"@channel the office is closed on Friday", "<@everyone> the office is closed on Friday"},
		{
			"Mentioning @dave, who will be gone soon, and @erin from the other team, in ~elsewhere",
			"Mentioning @dave, who will be gone soon, and @erin from the other team, in ~elsewhere",
		},
		{
			"Hello @bob and @carol, have a look at ~secret and ~general-talk :smile: :partyparrot:",
			"Hello <@3> and <@4>, have a look at #Secret and #General Talk Renamed \U0001F604 :partyparrot:",
		},
		{
			"an emoji shortcode with a skin tone :thumbsup_tone3:",
			"an emoji shortcode with a skin tone \U0001F44D",
		},
		{"Sushi :sushi:", "Sushi \U0001F363"},
		// Names: who, case, punctuation, the longest that is one.
		{"@Bob, @carol. @alice!", "<@3>, <@4>. <@5>!"},
		{"@bob.smith and @bob.", "<@6> and <@3>."},
		{"(@bob) [@carol](x) \"@alice\"", "(<@3>) [<@4>](x) \"<@5>\""},
		{"@bob's", "<@3>'s"},
		{"@nobody @bob_", "@nobody <@3>_"},
		{"@all-hands and @here_now", "@all-hands and @here_now"},
		// Not mentions: an address, a path, a word.
		{"mail me at bob@bob.com or a@carol", "mail me at bob@bob.com or a@carol"},
		{"https://x.example/@bob and /@carol", "https://x.example/@bob and /@carol"},
		{"alone @ and @@bob", "alone @ and @@bob"},
		// Channels.
		{
			"~off-topic is not ~~off-topic~~, and a~off-topic neither",
			"#Off-Topic is not ~~off-topic~~, and a~off-topic neither",
		},
		{"see ~secret-, ~unknown", "see #Secret-, ~unknown"},
		// Emoji.
		{":thumbsup: :+1: :heart:", "\U0001F44D \U0001F44D ❤"},
		{":Party-Time: :partyparrot_tone2: :nosuch:", ":party_time: :partyparrot: :nosuch:"},
		// A colon is not a word, so an emoji can follow one; a letter before it is part of a word.
		{"at 12:30:45 or ab:smile:cd or ::smile::", "at 12:30:45 or ab:smile:cd or :\U0001F604:"},
		{":foo:smile: :", ":foo:smile: :"},
		{":a: :1: :-: ::", ":a: :1: :-: ::"},
		// Code is left alone.
		{"`@bob :smile: ~secret` @bob", "`@bob :smile: ~secret` <@3>"},
		{"``a ` @bob`` @bob", "``a ` @bob`` <@3>"},
		// Backticks that are never closed by as many are only backticks.
		{"``@bob` @bob", "``<@3>` <@3>"},
		{"```\n@bob\n:smile:\n```\n@bob", "```\n@bob\n:smile:\n```\n<@3>"},
		{"  ```go\n@bob\n```\n@bob ~~~\n@bob", "  ```go\n@bob\n```\n<@3> ~~~\n<@3>"},
		{"~~~\n@bob\n~~~ trailing\n@bob", "~~~\n@bob\n~~~ trailing\n<@3>"},
		{"a block that never closes\n```\n@bob", "a block that never closes\n```\n@bob"},
		// Nothing to do, and the ends.
		{"", ""},
		{"plain text, no marks", "plain text, no marks"},
		{"@", "@"},
		{"@bob", "<@3>"},
		{"~", "~"},
		{":", ":"},
		{"ends with ~sec", "ends with ~sec"},
		{"line one @bob\nline two @carol\n", "line one <@3>\nline two <@4>\n"},
	}
	for c in cases {
		got := rewrite_text(&r, c.in_)
		testing.expectf(t, got.text == c.want, "%q: %q, not %q", c.in_, got.text, c.want)
	}

	// What is mentioned: each person once, and the groups.
	got := rewrite_text(&r, "@bob @carol @bob @channel @here, @bob.smith")
	testing.expect_value(t, len(got.accounts), 3)
	testing.expect(t, got.everyone && got.here)
	testing.expect_value(t, got.accounts[0], 3)
	testing.expect_value(t, got.accounts[1], 4)
	testing.expect_value(t, got.accounts[2], 6)
	got = rewrite_text(&r, "no one `@bob` here")
	testing.expect(t, len(got.accounts) == 0 && !got.everyone && !got.here)
	// Without the emoji map, emoji are left alone.
	r.emoji = nil
	testing.expect_value(t, rewrite_text(&r, ":smile: @bob").text, ":smile: <@3>")
}
