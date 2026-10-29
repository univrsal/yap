package server

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// The importer's bots, webhooks and cards (import_messages.odin), on the sample and
// on made-up exports.

@(private = "file")
run_hooks :: proc(t: ^testing.T, it: ^Import_Test) {
	it.im.emoji_dir = file_in(it.dir, "emoji")
	if !import_accounts(&it.im) ||
	   !import_channels(&it.im) ||
	   !import_emoji(&it.im) ||
	   !import_messages(&it.im) ||
	   !import_read_state(&it.im) {
		testing.fail_now(t, "the import failed")
	}
	db_commit(&it.db)
}

@(test)
test_import_hooks_sample :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_hooks(t, &it)

	// A bot for the webhook, which has no password and is in the home channel only.
	hook := account_find(&it.accounts, "ci_hook")
	testing.expect(t, hook != nil)
	if hook == nil {
		return
	}
	testing.expect_value(t, hook.flags, proto.Account_Flags{.Bot})
	testing.expect_value(t, hook.display, "CI hook")
	testing.expect_value(t, len(it.im.passwords), 6)
	testing.expect(t, conv_is_member(it.convs.home, hook.id))
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT count(*) FROM members WHERE account = %d", hook.id)),
		1,
	)

	// The post is the bot's, posing as Jenkins, and the card is quoted under the text.
	card, found := it_message(&it, "SELECT id FROM messages WHERE text LIKE 'Deploy finished%'")
	testing.expect(t, found)
	if found {
		testing.expect_value(t, card.sender, hook.id)
		testing.expect(t, .Persona in card.flags)
		testing.expect_value(t, card.persona.name, "Jenkins")
		testing.expect_value(t, card.persona.avatar, proto.Blob_Id(0)) // the picture isn't fetched unless asked
		testing.expect_value(
			t,
			card.text,
			"Deploy finished\n\n> Deploy report\n> [web 1.2.3](https://example.invalid/deploys/123)\n> Everything went *fine*\n> - **Env**: staging",
		)
	}
	// A bot's post that overrides its name keeps its bot, and the other has no persona.
	nightly, found2 := it_message(&it, "SELECT id FROM messages WHERE text = 'Build #42 failed'")
	testing.expect(t, found2)
	if found2 {
		testing.expect_value(t, it.accounts.by_id[nightly.sender].username, "buildbot")
		testing.expect_value(t, nightly.persona.name, "Nightly")
	}
	plain, found3 := it_message(&it, "SELECT id FROM messages WHERE text = 'Build #41 passed'")
	testing.expect(t, found3)
	testing.expect(t, .Persona not_in plain.flags)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE persona_name IS NOT NULL"),
		2,
	)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE flags & 32 != 0"),
		2,
	)
	// The bot's greeting in a DM is left out, as before.
	testing.expect_value(t, it.im.messages, 86)
	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
}

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`

@(private = "file")
hook_post :: proc(channel, user, message, props: string, at: int) -> string {
	return fmt.tprintf(
		`{{"type":"post","post":{{"team":"acme","channel":"%s","user":"%s","message":"%s","create_at":%d,"props":%s}}}}`,
		channel,
		user,
		message,
		at,
		props,
	)
}

@(test)
test_import_hooks_cases :: proc(t: ^testing.T) {
	member :: proc(name: string, roles: string) -> string {
		return fmt.tprintf(
			`{{"type":"user","user":{{"username":"%s","roles":"%s","teams":[{{"name":"acme","roles":"team_user","channels":[{{"name":"a","roles":"channel_user"}}]}}]}}}}`,
			name,
			roles,
		)
	}
	lines := []string {
		VERSION,
		`{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`,
		`{"type":"channel","channel":{"team":"acme","name":"a","display_name":"a","type":"O"}}`,
		member("root", "system_admin"),
		member("bob", "system_user"),
		// A real person who has the username that a webhook's bot would get.
		member("ci_hook", "system_user"),
		`{"type":"direct_channel","direct_channel":{"participants":[{"username":"root"},{"username":"bob"}]}}`,
		// A hook posing as a person (bob), and as itself, and under a name with a mention, and with no override.
		hook_post(
			"a",
			"root",
			"as bob",
			`{"from_webhook":"true","webhook_display_name":"CI hook","override_username":"Bob"}`,
			100,
		),
		hook_post(
			"a",
			"root",
			"as itself",
			`{"from_webhook":"true","webhook_display_name":"CI hook","override_username":"ci hook"}`,
			200,
		),
		hook_post(
			"a",
			"root",
			"as a name",
			`{"from_webhook":"true","webhook_display_name":"CI hook","override_username":"Deploys"}`,
			300,
		),
		hook_post(
			"a",
			"root",
			"no override",
			`{"from_webhook":"true","webhook_display_name":"CI hook"}`,
			400,
		),
		// An older hook that has only the name it poses under: the bot is named after it.
		hook_post(
			"a",
			"root",
			"old hook",
			`{"from_webhook":"true","override_username":"Old Grafana"}`,
			500,
		),
		// A hook with nothing: it stays with its author.
		hook_post("a", "root", "nameless", `{"from_webhook":"true"}`, 600),
		// A hook that only ever posted in a DM: no bot, the author stays, the name starts the post.
		`{"type":"direct_post","direct_post":{"channel_members":["root","bob"],"user":"root","message":"in a dm","create_at":700,"props":{"from_webhook":"true","webhook_display_name":"DM hook","override_username":"Reminder"}}}`,
		// Only a card.
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","type":"slack_attachment","message":"","create_at":800,"props":{"from_webhook":"true","webhook_display_name":"CI hook","attachments":[{"title":"Only a card","text":"mention @bob"}]}}}`,
	}
	dir := export_of(t, ..lines)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	// The webhooks that posted in a channel get a bot each: CI hook, and Old Grafana.
	testing.expect_value(t, len(it.scan.webhooks), 2)
	run_hooks(t, &it)

	// The bot of "CI hook" is not the person called ci_hook.
	person := account_find(&it.accounts, "ci_hook")
	bot := account_find(&it.accounts, "ci_hook_2")
	grafana := account_find(&it.accounts, "old_grafana")
	testing.expect(t, person != nil && bot != nil && grafana != nil)
	if person == nil || bot == nil || grafana == nil {
		return
	}
	testing.expect_value(t, person.flags, proto.Account_Flags{.Must_Change})
	testing.expect_value(t, bot.flags, proto.Account_Flags{.Bot})
	testing.expect_value(t, bot.display, "CI hook")
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM accounts WHERE flags & 32 != 0"),
		2,
	)

	// Posing as a person isn't allowed: the post says it instead.
	as_bob, _ := it_message(&it, "SELECT id FROM messages WHERE text LIKE '%as bob'")
	testing.expect_value(t, as_bob.text, "**Bob**\nas bob")
	testing.expect_value(t, as_bob.sender, bot.id)
	testing.expect(t, .Persona not_in as_bob.flags)
	testing.expect_value(t, it.scan.issues[.Persona_Dropped].count, 1)
	// Posing as itself is just itself.
	itself, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'as itself'")
	testing.expect(t, .Persona not_in itself.flags)
	testing.expect_value(t, itself.sender, bot.id)
	// A name that nobody has is a persona of the hook's bot.
	named, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'as a name'")
	testing.expect(t, .Persona in named.flags)
	testing.expect_value(t, named.persona.name, "Deploys")
	testing.expect_value(t, named.sender, bot.id)
	none, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'no override'")
	testing.expect(t, .Persona not_in none.flags)
	testing.expect_value(t, none.sender, bot.id)
	// The older hook is a bot named after the name it poses under, as that.
	old, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'old hook'")
	testing.expect_value(t, old.sender, grafana.id)
	testing.expect_value(t, grafana.display, "Old Grafana")
	testing.expect(t, .Persona not_in old.flags) // it poses as itself
	// A hook with nothing stays with its author.
	nameless, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'nameless'")
	testing.expect_value(t, it.accounts.by_id[nameless.sender].username, "root")
	// In a DM there is no bot: the author stays and the name is in bold.
	in_dm, _ := it_message(&it, "SELECT id FROM messages WHERE text LIKE '%in a dm'")
	testing.expect_value(t, in_dm.text, "**Reminder**\nin a dm")
	testing.expect_value(t, it.accounts.by_id[in_dm.sender].username, "root")
	testing.expect(t, account_find(&it.accounts, "dm_hook") == nil)
	// A post that is only a card is the card, and what it says goes through the same rewriting.
	card, _ := it_message(&it, "SELECT id FROM messages WHERE text LIKE '> **Only a card**%'")
	testing.expect_value(
		t,
		card.text,
		fmt.tprintf("> **Only a card**\n> mention %s", token(&it, "bob")),
	)
	testing.expect_value(t, card.sender, bot.id)
	testing.expect_value(t, it.scan.issues[.Post_Empty].count, 0)
	// Everything is where the server expects it.
	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	_ = strings.contains
}
