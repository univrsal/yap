package mattermost

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import "common:proto"

// The mapping rules, from values of the sample export (tools/mattermost/sample)
// and from made-up ones for what the sample doesn't have.

@(private = "file")
arena_for_test :: proc(a: ^virtual.Arena) -> Allocator {
	_ = virtual.arena_init_growing(a)
	return virtual.arena_allocator(a)
}

@(test)
test_usernames :: proc(t: ^testing.T) {
	arena: virtual.Arena
	a := arena_for_test(&arena)
	defer virtual.arena_destroy(&arena)
	names := unique_make(.Underscore, a)

	// Mattermost's own names are kept as they are.
	for raw in ([]string{"alice", "bob.smith", "carol-1", "dave_x"}) {
		name, changed := username_of(&names, raw)
		testing.expect_value(t, name, raw)
		testing.expect(t, !changed)
	}
	// Capitals, other characters and the cases that a second account has the same name.
	name, changed := username_of(&names, "Alice")
	testing.expect_value(t, name, "alice_2")
	testing.expect(t, changed)
	name, _ = username_of(&names, "alice")
	testing.expect_value(t, name, "alice_3")
	name, _ = username_of(&names, "zoë smith")
	testing.expect_value(t, name, "zo__smith") // ë is one character, a space another
	name, _ = username_of(&names, "")
	testing.expect_value(t, name, "user")
	// Long names are cut to make room for the number.
	long := strings.repeat("x", proto.MAX_USERNAME_SIZE + 10, context.temp_allocator)
	first, _ := username_of(&names, long)
	second, _ := username_of(&names, long)
	testing.expect_value(t, len(first), proto.MAX_USERNAME_SIZE)
	testing.expect_value(t, len(second), proto.MAX_USERNAME_SIZE)
	testing.expect(t, first != second)
	// Every name is one yap accepts.
	buf: [proto.MAX_USERNAME_SIZE]u8
	for n in ([]string{first, second, "zo__smith", "user", "alice_3"}) {
		_, ok := proto.username_clean(n, &buf)
		testing.expectf(t, ok, "%q", n)
	}
}

@(test)
test_display_names :: proc(t: ^testing.T) {
	// The sample's users: a nickname, a first and last name, a first name only,
	// and nothing.
	testing.expect_value(t, display_of({username = "bob", nickname = "Bobby"}), "Bobby")
	testing.expect_value(
		t,
		display_of({username = "frank", first_name = "Frank", last_name = "Fisher"}),
		"Frank Fisher",
	)
	testing.expect_value(t, display_of({username = "dave", first_name = "Dave"}), "Dave")
	testing.expect_value(t, display_of({username = "gus"}), "gus")
	testing.expect_value(t, display_of({username = "x", nickname = "  \t "}), "x")
	testing.expect_value(t, display_of({username = "x", nickname = "A\nB\x07"}), "A B")
	testing.expect_value(
		t,
		bot_display_of({username = "buildbot", display_name = "Build Bot"}),
		"Build Bot",
	)
	testing.expect_value(t, bot_display_of({username = "calls"}), "calls")
	// A name at Mattermost's limit (64 characters of 4 bytes, a space, 64) fits.
	long := strings.repeat("\U0001F600", 64, context.temp_allocator)
	name := display_of({username = "x", first_name = long, last_name = long})
	testing.expect_value(t, len(name), 4 * 64 + 1 + 4 * 64)
	testing.expect(t, len(name) <= proto.MAX_NAME_SIZE)
}

@(test)
test_emails :: proc(t: ^testing.T) {
	arena: virtual.Arena
	a := arena_for_test(&arena)
	defer virtual.arena_destroy(&arena)
	taken := make(map[string]bool, a)
	address, problem := email_of(&taken, "Bob@Example.invalid", a)
	testing.expect_value(t, address, "bob@example.invalid")
	testing.expect_value(t, problem, Email_Problem.None)
	address, problem = email_of(&taken, "bob@example.invalid", a)
	testing.expect_value(t, address, "")
	testing.expect_value(t, problem, Email_Problem.Taken)
	_, problem = email_of(&taken, "not an address", a)
	testing.expect_value(t, problem, Email_Problem.Invalid)
	// None at all is not a problem.
	address, problem = email_of(&taken, "", a)
	testing.expect_value(t, address, "")
	testing.expect_value(t, problem, Email_Problem.None)
}

@(test)
test_channel_plans :: proc(t: ^testing.T) {
	arena: virtual.Arena
	a := arena_for_test(&arena)
	defer virtual.arena_destroy(&arena)
	// The sample's channels of the team, in its order, and two made up.
	channels := []Channel {
		{name = "town-square", display_name = "Town Square", type = "O"},
		{name = "off-topic", display_name = "Off-Topic", type = "O"},
		{
			name = "secret",
			display_name = "Secret",
			type = "P",
			purpose = "Only a purpose, no header",
		},
		{
			name = "general-talk",
			display_name = "General Talk Renamed",
			type = "O",
			header = "Talk about *anything* (really)",
			purpose = "The main channel, still",
		},
		{name = "old-stuff", display_name = "Old Stuff", type = "O", deleted_at = 1793200879359},
		// The archived one comes first in the export but the active one is named first.
		{name = "a1", display_name = "Plans", type = "O", deleted_at = 5},
		{name = "a2", display_name = "plans", type = "O"},
		{name = "a3", display_name = "", type = "O"},
	}
	plans := plan_channels(channels, a)

	home := plans[0]
	testing.expect_value(t, home.name, "Town Square")
	testing.expect(t, home.home)
	testing.expect_value(t, home.flags, proto.Conv_Flags{.Text_Only})

	testing.expect_value(t, plans[1].name, "Off-Topic")
	testing.expect_value(t, plans[1].flags, proto.Conv_Flags{.Text_Only, .Default})
	testing.expect(t, !plans[1].home)

	// A private channel without a header has its purpose as its topic, and is not
	// the default channel whatever it is called.
	testing.expect_value(t, plans[2].topic, "Only a purpose, no header")
	testing.expect(t, plans[2].from_purpose)
	testing.expect_value(t, plans[2].flags, proto.Conv_Flags{.Text_Only, .Private})

	// The header wins over the purpose, and the display name over the name.
	testing.expect_value(t, plans[3].name, "General Talk Renamed")
	testing.expect_value(t, plans[3].topic, "Talk about *anything* (really)")
	testing.expect(t, !plans[3].from_purpose)

	testing.expect_value(t, plans[4].flags, proto.Conv_Flags{.Text_Only, .Archived})

	testing.expect_value(t, plans[6].name, "plans")
	testing.expect_value(t, plans[5].name, "Plans (2)")
	testing.expect(t, plans[5].renamed)
	testing.expect_value(t, plans[7].name, "a3") // no display name: the name

	// An archived channel called off-topic is not the default.
	archived := plan_channel(
		{name = "off-topic", display_name = "x", type = "O", deleted_at = 1},
		&Unique{taken = make(map[string]bool, a), allocator = a},
		a,
	)
	testing.expect_value(t, archived.flags, proto.Conv_Flags{.Text_Only, .Archived})

	// Limits: a name at Mattermost's limit fits whole, and a header's lines become one line.
	big := strings.repeat("\U0001F600", 64, context.temp_allocator)
	p := plan_channel(
		{name = "x", display_name = big, type = "O", header = "a\nb"},
		&Unique{taken = make(map[string]bool, a), allocator = a},
		a,
	)
	testing.expect_value(t, len(p.name), 256)
	testing.expect(t, !p.cut_name)
	testing.expect_value(t, p.topic, "a b")
	tiny := plan_channel(
		{
			name = "x",
			display_name = strings.repeat("\U0001F600", 100, context.temp_allocator),
			type = "O",
		},
		&Unique{taken = make(map[string]bool, a), allocator = a},
		a,
	)
	testing.expect(t, tiny.cut_name)
	testing.expect_value(t, len(tiny.name), 256)
	testing.expect(t, utf8.valid_string(tiny.name))
}

@(test)
test_notify :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		notify_of({desktop = "default", mark_unread = "all"}),
		proto.Notify_Level.All,
	)
	testing.expect_value(
		t,
		notify_of({desktop = "default", mark_unread = "mention"}),
		proto.Notify_Level.Mentions,
	)
	testing.expect_value(
		t,
		notify_of({desktop = "all", mark_unread = "mention"}),
		proto.Notify_Level.All,
	)
	testing.expect_value(t, notify_of({desktop = "mention"}), proto.Notify_Level.Mentions)
	testing.expect_value(
		t,
		notify_of({desktop = "none", mark_unread = "all"}),
		proto.Notify_Level.None,
	)
	testing.expect_value(t, notify_of({}), proto.Notify_Level.All)
}

@(test)
test_roles :: proc(t: ^testing.T) {
	// The sample's alice is a team admin and admin a system admin.
	alice := User {
		username = "alice",
		roles    = "system_user",
		teams    = {
			{name = "acme", roles = "team_admin team_user"},
			{name = "other", roles = "team_user"},
		},
	}
	testing.expect_value(t, roles_of(alice, "acme"), Account_Roles{admin = true})
	testing.expect_value(t, roles_of(alice, "other"), Account_Roles{})
	testing.expect_value(
		t,
		roles_of({roles = "system_user system_admin"}, "acme"),
		Account_Roles{admin = true},
	)
	testing.expect_value(
		t,
		roles_of({roles = "system_guest"}, "acme"),
		Account_Roles{guest = true},
	)
	testing.expect(t, is_channel_admin("channel_user channel_admin"))
	testing.expect(t, !is_channel_admin("channel_user"))
	testing.expect(t, !is_channel_admin("my_channel_admin_like"))
}

@(test)
test_choose_owner :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	// The first system admin, by default.
	owner, msg := choose_owner(s, "")
	testing.expect_value(t, owner, "admin")
	testing.expect_value(t, msg, "")
	owner, _ = choose_owner(s, "alice")
	testing.expect_value(t, owner, "alice")
	// Not a member of the team (erin is in the other one), or not there at all.
	_, msg = choose_owner(s, "erin")
	testing.expect(t, msg != "")
	_, msg = choose_owner(s, "nobody")
	testing.expect(t, msg != "")
	// Deactivated accounts can't be owners, by default or by name.
	for &u in s.users {
		if u.username == "admin" {
			u.delete_at = 1
		}
	}
	_, msg = choose_owner(s, "admin")
	testing.expect(t, strings.contains(msg, "deactivated"))
	_, msg = choose_owner(s, "")
	testing.expect(t, strings.contains(msg, "--owner"))
}

@(private = "file")
props_of :: proc(text: string, allocator: Allocator) -> json.Value {
	v, _ := json.parse(transmute([]u8)text, allocator = allocator)
	return v
}

@(test)
test_system_posts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	a := arena_for_test(&arena)
	defer virtual.arena_destroy(&arena)
	Case :: struct {
		type, message, props: string,
		header:               bool,
		result:               System_Result,
		post:                 System_Post,
	}
	// The props and messages are the sample's.
	cases := []Case {
		{
			"system_join_channel",
			"frank joined the channel.",
			`{"username":"frank"}`,
			false,
			.Mapped,
			{what = .Joined},
		},
		{
			"system_leave_channel",
			"@frank left the channel.",
			`{"username":"frank"}`,
			false,
			.Mapped,
			{what = .Left},
		},
		{
			"system_add_to_channel",
			"bob added to the channel by admin.",
			`{"addedUsername":"bob","username":"admin"}`,
			false,
			.Mapped,
			{what = .Added, arg = "bob"},
		},
		{
			"system_remove_from_channel",
			"@gus removed from the channel.",
			`{"removedUsername":"gus"}`,
			false,
			.Mapped,
			{what = .Removed, arg = "gus"},
		},
		{
			"system_displayname_change",
			"...",
			`{"old_displayname":"General Talk","new_displayname":"General Talk Renamed"}`,
			false,
			.Mapped,
			{what = .Renamed, text = "General Talk\nGeneral Talk Renamed"},
		},
		{
			"system_header_change",
			"...",
			`{"old_header":"Talk about *anything*","new_header":"Talk about *anything* (really)"}`,
			true,
			.Mapped,
			{
				what = .Topic_Changed,
				text = "Talk about *anything*\nTalk about *anything* (really)",
			},
		},
		// A header with lines is one line in a system message's text.
		{
			"system_header_change",
			"...",
			`{"old_header":"a\nb","new_header":""}`,
			true,
			.Mapped,
			{what = .Topic_Changed, text = "a b\n"},
		},
		// The purpose is the topic only where there is no header.
		{
			"system_purpose_change",
			"...",
			`{"old_purpose":"The main channel","new_purpose":"The main channel, still"}`,
			false,
			.Mapped,
			{what = .Topic_Changed, text = "The main channel\nThe main channel, still"},
		},
		{
			"system_purpose_change",
			"...",
			`{"old_purpose":"x","new_purpose":"y"}`,
			true,
			.Dropped,
			{},
		},
		{
			"system_change_chan_privacy",
			"This channel has been converted to a Public Channel and can be joined by any team member.",
			`{"username":"admin"}`,
			false,
			.Mapped,
			{what = .Made_Public},
		},
		{
			"system_change_chan_privacy",
			"This channel has been converted to a Private Channel.",
			`{}`,
			false,
			.Mapped,
			{what = .Made_Private},
		},
		{
			"system_change_chan_privacy",
			"Dieser Kanal wurde geändert.",
			`{}`,
			false,
			.Incomplete,
			{},
		},
		{
			"system_channel_deleted",
			"admin archived the channel.",
			`{"username":"admin"}`,
			false,
			.Mapped,
			{what = .Archived},
		},
		{
			"system_channel_restored",
			"admin unarchived the channel.",
			`{"username":"admin"}`,
			false,
			.Mapped,
			{what = .Unarchived},
		},
		{
			"system_join_team",
			"gus joined the team.",
			`{"username":"gus"}`,
			false,
			.Mapped,
			{what = .Joined_Server},
		},
		{
			"system_leave_team",
			"frank left the team.",
			`{"username":"frank"}`,
			false,
			.Mapped,
			{what = .Left_Server},
		},
		{
			"system_add_to_team",
			"",
			`{"addedUsername":"gus"}`,
			false,
			.Mapped,
			{what = .Joined_Server, who = "gus"},
		},
		{
			"system_remove_from_team",
			"",
			`{"removedUsername":"gus"}`,
			false,
			.Mapped,
			{what = .Left_Server, who = "gus"},
		},
		// Not enough in the export to say whom.
		{"system_add_to_channel", "", `{}`, false, .Incomplete, {}},
		{"system_remove_from_channel", "", `{}`, false, .Incomplete, {}},
		// Left out, and what isn't known.
		{"system_generic", "", `{}`, false, .Dropped, {}},
		{"add_bot_teams_channels", "Please add me", `{"from_bot":"true"}`, false, .Dropped, {}},
		{"system_join_leave", "", `{}`, false, .Dropped, {}},
		{"system_something_new", "", `{}`, false, .Unknown, {}},
		// Not system posts: normal, /me, a webhook's card, a reminder.
		{"", "hello", `{}`, false, .Not_System, {}},
		{"me", "*waves*", `{}`, false, .Not_System, {}},
		{"slack_attachment", "Deploy finished", `{}`, false, .Not_System, {}},
		{"reminder", "You asked me to remind you", `{}`, false, .Not_System, {}},
	}
	for c in cases {
		got, result := map_system(c.type, c.message, props_of(c.props, a), c.header, a)
		testing.expectf(
			t,
			result == c.result,
			"%s %s: %v, not %v",
			c.type,
			c.props,
			result,
			c.result,
		)
		if result == .Mapped {
			testing.expectf(t, got == c.post, "%s: %v, not %v", c.type, got, c.post)
		}
	}
	// A post without props.
	_, result := map_system("system_join_channel", "", nil, false, a)
	testing.expect_value(t, result, System_Result.Mapped)
}

@(test)
test_reactions :: proc(t: ^testing.T) {
	arena: virtual.Arena
	a := arena_for_test(&arena)
	defer virtual.arena_destroy(&arena)
	m := emoji_map_make(a)
	names := unique_make(.Underscore, a)
	yap_name, changed := custom_emoji_name(&names, "partyparrot")
	testing.expect_value(t, yap_name, "partyparrot")
	testing.expect(t, !changed)
	emoji_add_custom(&m, "partyparrot", yap_name)
	emoji_add_custom(&m, "odd_tone2", "odd_tone2")

	// The sample's reactions: both spellings of the thumbs up, a heart, a pizza and a custom emoji.
	for c in ([]struct {
			name, want: string,
			result:     Reaction_Result,
		} {
			{"thumbsup", "\U0001F44D", .Mapped},
			{"+1", "\U0001F44D", .Mapped},
			{"heart", "❤", .Mapped},
			{"pizza", "\U0001F355", .Mapped},
			{"partyparrot", ":partyparrot:", .Mapped},
			{":thumbsup:", "\U0001F44D", .Mapped},
			// Skin tones are dropped, in both of Mattermost's spellings.
			{"thumbsup_tone3", "\U0001F44D", .Tone_Dropped},
			{"+1::skin-tone-4", "\U0001F44D", .Tone_Dropped},
			{"odd_tone2", ":odd_tone2:", .Mapped},
			{"nosuchemoji", "", .Unknown},
			// A custom emoji has no tones; it is also free to be called what it likes.
			{"partyparrot_tone2", ":partyparrot:", .Mapped},
			{"wave_tone5", "\U0001F44B", .Tone_Dropped},
		}) {
		got, result := map_reaction(&m, c.name, a)
		testing.expectf(
			t,
			got == c.want && result == c.result,
			"%s: %q %v, not %q %v",
			c.name,
			got,
			result,
			c.want,
			c.result,
		)
	}

	// Custom names that yap doesn't allow, and the same one twice.
	for c in ([]struct {
			raw, want: string,
		} {
			{"Party-Parrot", "party_parrot"},
			{"a", "a_"},
			{"cool+1", "cool_1"},
			{"partyparrot", "partyparrot_2"},
		}) {
		got, _ := custom_emoji_name(&names, c.raw)
		testing.expectf(t, got == c.want, "%s: %q, not %q", c.raw, got, c.want)
		testing.expect(t, proto.custom_emoji_name_ok(got))
	}
}

@(test)
test_clean_text :: proc(t: ^testing.T) {
	text, cut := clean_text("  a\tb\n", 10)
	testing.expect_value(t, text, "a b")
	testing.expect(t, !cut)
	// Cut on a character's boundary.
	text, cut = clean_text("abécd", 3)
	testing.expect_value(t, text, "ab")
	testing.expect(t, cut)
	message, message_cut := clean_message("line 1\r\nline 2")
	testing.expect_value(t, message, "line 1\nline 2")
	testing.expect(t, !message_cut)
	huge := strings.repeat("x", proto.MAX_CHAT_SIZE + 5, context.temp_allocator)
	message, message_cut = clean_message(huge)
	testing.expect_value(t, len(message), proto.MAX_CHAT_SIZE)
	testing.expect(t, message_cut)
}
