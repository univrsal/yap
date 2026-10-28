package mattermost

import "core:os"
import "core:strings"
import "core:testing"


@(test)
test_plan_sample :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	testing.expect_value(t, build_plan(s, ""), "")
	p := s.plan

	testing.expect_value(t, p.owner, "admin")
	// Seven members, three bots, nobody who left the team.
	testing.expect_value(t, len(p.accounts), 10)
	bots := 0
	for acc in p.accounts {
		bots += int(acc.bot)
		testing.expectf(t, acc.name == acc.mm_name, "%s became %s", acc.mm_name, acc.name)
		testing.expect(t, acc.display != "")
	}
	testing.expect_value(t, bots, 3)
	owner := p.accounts[p.by_name["admin"]]
	testing.expect(t, owner.owner && owner.admin)
	testing.expect_value(t, owner.display, "The Admin")
	alice := p.accounts[p.by_name["alice"]]
	testing.expect(t, alice.admin && !alice.owner) // a team admin
	testing.expect_value(t, alice.display, "Alice Archer")
	testing.expect_value(t, alice.email, "alice@example.invalid")
	testing.expect(t, p.accounts[p.by_name["dave"]].disabled) // deactivated
	testing.expect(t, !p.accounts[p.by_name["bob"]].disabled)
	testing.expect_value(t, p.accounts[p.by_name["bob"]].display, "Bobby")
	testing.expect(t, p.accounts[p.by_name["buildbot"]].bot)

	// The sample's channels, in its order.
	names := make([dynamic]string, context.temp_allocator)
	for c in p.channels {
		append(&names, c.name)
	}
	testing.expect_value(
		t,
		strings.join(names[:], "|", context.temp_allocator),
		"Town Square|Off-Topic|Phoenix|Secret|General Talk Renamed|Old Stuff",
	)
	home := 0
	for c in p.channels {
		home += int(c.home)
	}
	testing.expect_value(t, home, 1)

	// Reactions: thumbsup and +1 are yap's emoji and partyparrot is custom, so
	// nothing is left out; the only warning is the one of the scan and the system
	// post type that yap has no use for.
	testing.expect_value(t, s.issues[.Reaction_Unknown].count, 0)
	testing.expect_value(t, s.issues[.Username_Changed].count, 0)
	testing.expect_value(t, s.issues[.Channel_Renamed].count, 0)
	testing.expect_value(t, s.issues[.System_Dropped].count, 1)
	testing.expect_value(t, s.issues[.System_Dropped].examples[0], "add_bot_teams_channels (1)")
	testing.expect_value(t, s.issues[.System_Unknown].count, 0)
	got, result := map_reaction(&p.emoji, "partyparrot", context.temp_allocator)
	testing.expect_value(t, got, ":partyparrot:")
	testing.expect_value(t, result, Reaction_Result.Mapped)

	// The owner can be named.
	s2, _ := scan({dir = SAMPLE, team = "acme"})
	defer scan_destroy(s2)
	testing.expect_value(t, build_plan(s2, "alice"), "")
	testing.expect_value(t, s2.plan.owner, "alice")
	testing.expect(t, s2.plan.accounts[s2.plan.by_name["alice"]].owner)
	testing.expect(t, !s2.plan.accounts[s2.plan.by_name["admin"]].owner)
	s3, _ := scan({dir = SAMPLE, team = "acme"})
	defer scan_destroy(s3)
	msg := build_plan(s3, "erin")
	testing.expect(t, msg != "")
	delete(msg)
}

@(test)
test_plan_problems :: proc(t: ^testing.T) {
	user :: proc(name, email, extra: string) -> string {
		return strings.concatenate(
			{
				`{"type":"user","user":{"username":"`,
				name,
				`","email":"`,
				email,
				`","roles":"system_user system_admin","teams":[{"name":"acme","roles":"team_user","channels":[]}]`,
				extra,
				`}}`,
			},
			context.temp_allocator,
		)
	}
	dir := export_with(
		t,
		VERSION,
		TEAM,
		`{"type":"channel","channel":{"team":"acme","name":"a","display_name":"Plans","type":"O","deleted_at":5}}`,
		`{"type":"channel","channel":{"team":"acme","name":"b","display_name":"plans","type":"O"}}`,
		user("Alice", "a@example.invalid", ""),
		user("alice", "A@example.invalid", ""), // the same name and address
		user("bob smith", "not an address", ""),
		`{"type":"bot","bot":{"username":"ci"}}`,
		// An author who has left the team: a user line without the membership.
		`{"type":"user","user":{"username":"leaver","email":"l@example.invalid","roles":"system_user","teams":[{"name":"other","roles":"team_user","channels":[]}]}}`,
		`{"type":"post","post":{"team":"acme","channel":"b","user":"leaver","message":"x","create_at":1,"reactions":[{"user":"ci","emoji_name":"thumbsup_tone3","create_at":2},{"user":"ci","emoji_name":"nosuchemoji","create_at":2}]}}`,
		`{"type":"post","post":{"team":"acme","channel":"b","user":"ci","type":"system_something_new","message":"x","create_at":3}}`,
	)
	defer os.remove_all(dir)
	s, err := scan({dir = dir, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	// Only "Alice" gets in: usernames are lower case, so "alice" is the same one.
	testing.expect_value(t, s.issues[.Duplicate_User].count, 0) // they differ as Mattermost has them
	testing.expect_value(t, build_plan(s, ""), "")
	p := s.plan

	testing.expect_value(t, p.accounts[p.by_name["Alice"]].name, "alice")
	testing.expect_value(t, p.accounts[p.by_name["alice"]].name, "alice_2")
	testing.expect_value(t, p.accounts[p.by_name["bob smith"]].name, "bob_smith")
	testing.expect_value(t, s.issues[.Username_Changed].count, 3)

	testing.expect_value(t, p.accounts[p.by_name["Alice"]].email, "a@example.invalid")
	testing.expect_value(t, p.accounts[p.by_name["alice"]].email, "")
	testing.expect_value(t, s.issues[.Email_Taken].count, 1)
	testing.expect_value(t, s.issues[.Email_Invalid].count, 1)

	// The one who left the team has a disabled account of their own, after the others.
	leaver := p.accounts[p.by_name["leaver"]]
	testing.expect(t, leaver.author_only && leaver.disabled)
	testing.expect_value(t, len(p.accounts), 5)

	// The active channel gets the name, the archived one a number.
	testing.expect_value(t, p.channels[1].name, "plans")
	testing.expect_value(t, p.channels[0].name, "Plans (2)")
	testing.expect_value(t, p.owner, "alice") // the first admin, as yap names it
	testing.expect_value(t, s.issues[.Channel_Renamed].count, 1)

	testing.expect_value(t, s.issues[.Reaction_Tone].count, 1)
	testing.expect_value(t, s.issues[.Reaction_Unknown].count, 1)
	testing.expect_value(t, s.issues[.System_Unknown].count, 1)
	testing.expect_value(t, s.issues[.Author_Not_Member].count, 1)

	// The report lists them all.
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	report_write(s, strings.to_stream(&b))
	text := strings.to_string(b)
	for want in ([]string {
			"alice_2",
			"bob smith -> bob_smith",
			"nosuchemoji (1)",
			"system_something_new (1)",
			"Plans (2)",
			"the owner: alice",
			"3 accounts of the team's members, 1 bots, 1 disabled",
		}) {
		testing.expectf(t, strings.contains(text, want), "the report lacks %q:\n%s", want, text)
	}
}

@(test)
test_plan_no_owner :: proc(t: ^testing.T) {
	dir := export_with(t, VERSION, TEAM, CHANNEL, USER)
	defer os.remove_all(dir)
	s, _ := scan({dir = dir, team = "acme"})
	defer scan_destroy(s)
	// USER is an ordinary member, so there is no admin to make the owner.
	msg := build_plan(s, "")
	testing.expect(t, strings.contains(msg, "--owner"))
	delete(msg)
	testing.expect_value(t, build_plan(s, "alice"), "")
}
