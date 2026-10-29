package server

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// The importer's text rewriting and mentions (import_messages.odin), on the sample,
// whose posts have all of it.

@(private = "file")
run_text :: proc(t: ^testing.T, it: ^Import_Test) {
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

@(private = "file")
token :: proc(it: ^Import_Test, username: string) -> string {
	return fmt.tprintf("<@%d>", account_find(&it.accounts, username).id)
}

@(test)
test_import_text :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_text(t, &it)

	// The sample's posts, as they read now.
	for check in ([]struct {
			want: string,
		} {
			{fmt.tprintf("Pizza it is, thanks %s", token(&it, "bob"))},
			{"<@here> quick one: standup moved to 10:00"},
			{"<@everyone> please update your profiles"},
			{"<@everyone> the office is closed on Friday"},
			{"Sushi \U0001F363"},
			{
				"Unicode: Grüße, こんにちは, 🎉👍🏽, and an emoji shortcode with a skin tone \U0001F44D",
			},
			// A person who is gone soon is still there, one from the other team and
			// that team's channel are not.
			{
				fmt.tprintf(
					"Mentioning %s, who will be gone soon, and @erin from the other team, in ~elsewhere",
					token(&it, "dave"),
				),
			},
			{
				fmt.tprintf(
					"Hello %s and %s, have a look at #Secret and #General Talk Renamed \U0001F604 :partyparrot:",
					token(&it, "bob"),
					token(&it, "carol"),
				),
			},
		}) {
		quoted, _ := strings.replace_all(check.want, "'", "''", context.temp_allocator)
		n := it_count(
			&it,
			fmt.tprintf("SELECT count(*) FROM messages WHERE kind = 0 AND text = '%s'", quoted),
		)
		testing.expectf(t, n == 1, "%q is not a message (%d)", check.want, n)
	}
	// The markdown is untouched.
	md, ok := it_message(&it, "SELECT id FROM messages WHERE text LIKE 'Some **Markdown**%'")
	testing.expect(t, ok)
	testing.expect(t, strings.contains(md.text, "```python\nprint('a code block')\n```"))
	testing.expect(t, strings.contains(md.text, "[link](https://example.invalid/page)"))

	// Who was mentioned and hasn't read it has a mention; nobody else does, and
	// @here is nobody's. The rule, in SQL: a member who isn't the author, after
	// what they have read, whose token the text has or which says @channel or @all.
	expected := it_count(
		&it,
		`SELECT count(*) FROM members mem JOIN messages msg ON msg.conv = mem.conv
		WHERE msg.kind = 0 AND msg.sender != mem.account AND msg.id > mem.read_id
		AND (instr(msg.text, '<@' || mem.account || '>') > 0 OR instr(msg.text, '<@everyone>') > 0)`,
	)
	testing.expect(t, expected > 0)
	testing.expect_value(t, it.im.mentions, int(expected))
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM mentions"), expected)
	// None for what was read, nor for someone who isn't in the conversation.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM mentions n JOIN members m ON m.conv = n.conv AND m.account = n.account WHERE n.message <= m.read_id",
		),
		0,
	)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM mentions n WHERE NOT EXISTS (SELECT 1 FROM members m WHERE m.conv = n.conv AND m.account = n.account)",
		),
		0,
	)
	// @here made none of its own: its message is mentioned by nobody.
	here, _ := it_message(&it, "SELECT id FROM messages WHERE text LIKE '<@here>%'")
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT count(*) FROM mentions WHERE message = %d", here.id)),
		0,
	)

	// And as the server counts them for a person who logs in.
	loaded: Convs
	testing.expect(t, convs_load(&loaded, &it.db, []string{DEFAULT_CHANNEL_NAME}, &it.accounts))
	defer convs_destroy(&loaded)
	total := 0
	for _, conv in loaded.by_id {
		for member in conv.members {
			total += conv_mentions(&loaded, conv, member, conv.reads[member].read)
		}
	}
	testing.expect_value(t, total, int(expected))

	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	_ = proto.MAX_PINS
}

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
@(private = "file")
TEAM :: `{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`

@(private = "file")
user :: proc(name, roles, channels: string) -> string {
	return fmt.tprintf(
		`{{"type":"user","user":{{"username":"%s","roles":"%s","teams":[{{"name":"acme","roles":"team_user","channels":[%s]}}]}}}}`,
		name,
		roles,
		channels,
	)
}

@(private = "file")
member :: proc(channel: string, viewed: int) -> string {
	return fmt.tprintf(
		`{{"name":"%s","roles":"channel_user","last_viewed_at":%d}}`,
		channel,
		viewed,
	)
}

@(private = "file")
post :: proc(channel, who, message: string, at: int) -> string {
	return fmt.tprintf(
		`{{"type":"post","post":{{"team":"acme","channel":"%s","user":"%s","message":"%s","create_at":%d}}}}`,
		channel,
		who,
		message,
		at,
	)
}

@(test)
test_import_mentions :: proc(t: ^testing.T) {
	// root, u1 and u2 are in the channel a; u3 is only in b. In a, u1 opened it at
	// 1500 (after the first post) and u2 never has.
	lines := []string {
		VERSION,
		TEAM,
		`{"type":"channel","channel":{"team":"acme","name":"a","display_name":"a","type":"O"}}`,
		`{"type":"channel","channel":{"team":"acme","name":"b","display_name":"b","type":"P"}}`,
		user("root", "system_admin", strings.join({member("a", 0)}, ",", context.temp_allocator)),
		user("u1", "system_user", member("a", 1500)),
		user("u2", "system_user", member("a", 0)),
		user("u3", "system_user", member("b", 0)),
		// everyone is told about this one, but u1 has read it.
		post("a", "root", "@channel ping", 1000),
		// u1 and u3 are mentioned: u3 is not in a; root mentions themselves; and the
		// mention in code and of someone unknown are nothing.
		post("a", "root", "@u1 @u3 @root `@u2` @nobody", 2000),
		// @here is nobody's, @all is everyone's.
		post("a", "root", "@here hello and @all", 3000),
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
	run_text(t, &it)

	has := proc(it: ^Import_Test, who, text: string) -> i64 {
		return it_count(
			it,
			fmt.tprintf(
				"SELECT count(*) FROM mentions n JOIN accounts a ON a.id = n.account JOIN messages m ON m.id = n.message WHERE a.username = '%s' AND m.text = '%s'",
				who,
				text,
			),
		)
	}
	ping := "<@everyone> ping"
	second := fmt.tprintf(
		"%s %s %s `@u2` @nobody",
		token(&it, "u1"),
		token(&it, "u3"),
		token(&it, "root"),
	)
	third := "<@here> hello and <@everyone>"
	// @channel: u2 hasn't read it, u1 has, the author is never told, and u3 isn't there.
	testing.expect_value(t, has(&it, "u2", ping), 1)
	testing.expect_value(t, has(&it, "u1", ping), 0)
	testing.expect_value(t, has(&it, "root", ping), 0)
	testing.expect_value(t, has(&it, "u3", ping), 0)
	// u1 read up to the first post, so the second is new to them.
	testing.expect_value(t, has(&it, "u1", second), 1)
	testing.expect_value(t, has(&it, "u3", second), 0) // not in the conversation
	testing.expect_value(t, has(&it, "root", second), 0) // the author
	testing.expect_value(t, has(&it, "u2", second), 0) // in code
	// @all in the last: everyone but its author, where it is new. u1 stopped at the
	// first post, and u2 never read anything. @here made none.
	testing.expect_value(t, has(&it, "u1", third), 1)
	testing.expect_value(t, has(&it, "u2", third), 1)
	testing.expect_value(t, has(&it, "root", third), 0)
	// The messages as they are written.
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT count(*) FROM messages WHERE text = '%s'", second)),
		1,
	)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM mentions"), 4)
	testing.expect_value(t, it.im.mentions, 4)
}
