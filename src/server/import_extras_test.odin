package server

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// The importer's reactions, pins and saved posts (import_messages.odin), from the
// sample export, whose "Pin and save me" post has all three.

@(private = "file")
run_import :: proc(t: ^testing.T, it: ^Import_Test) {
	if !import_accounts(&it.im) || !import_channels(&it.im) || !import_messages(&it.im) {
		testing.fail_now(t, "the import failed")
	}
	db_commit(&it.db)
}

@(test)
test_import_extras :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_import(t, &it)

	// Eight reactions: pizza, the DM reply's partyparrot, and the pinned post's
	// thumbs up from bob and carol (carol said both `thumbsup` and `+1`, which are
	// one emoji), a heart and a partyparrot; and the two that extras.jsonl adds
	// to the first posts of a DM and a group.
	testing.expect_value(t, it.im.reactions, 8)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM reactions"), 8)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM reactions WHERE emoji = '\U0001F44D'"),
		2,
	)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM reactions WHERE emoji = '❤'"), 1)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM reactions WHERE emoji = ':partyparrot:'"),
		2,
	)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM reactions WHERE emoji = '\U0001F44B'"),
		1,
	) // wave, from extras.jsonl
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM reactions WHERE emoji = '\U0001F604'"),
		1,
	) // smile
	// Their times are Mattermost's.
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM reactions WHERE time < 1793200000000"),
		0,
	)
	// The extra ones are on the first post of their direct channel, by who wrote it.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM reactions r JOIN messages m ON m.id = r.message JOIN convs c ON c.id = m.conv WHERE c.kind != 0 AND m.thread_root = 0 AND r.emoji IN ('\U0001F44B', '\U0001F604')",
		),
		2,
	)
	// Nothing was left out.
	testing.expect_value(t, it.scan.issues[.Reaction_User_Gone].count, 0)
	testing.expect_value(t, it.scan.issues[.Reaction_Unknown].count, 0)

	// One pin, in the channel it was pinned in, by the author, and the message knows.
	testing.expect_value(t, it.im.pins, 1)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM pins"), 1)
	pinned, ok := it_message(&it, "SELECT id FROM messages WHERE text = 'Pin and save me' LIMIT 1")
	testing.expect(t, ok)
	if ok {
		testing.expect(t, .Pinned in pinned.flags)
		testing.expect_value(
			t,
			it_count(
				&it,
				fmt.tprintf(
					"SELECT count(*) FROM pins WHERE message = %d AND conv = %d",
					pinned.id,
					pinned.conv,
				),
			),
			1,
		)
		testing.expect_value(
			t,
			it_count(&it, fmt.tprintf("SELECT by FROM pins WHERE message = %d", pinned.id)),
			i64(pinned.sender),
		)
		testing.expect_value(t, it.accounts.by_id[pinned.sender].username, "alice")
		// Saved by bob and carol, at the post's time.
		testing.expect_value(t, it.im.bookmarks, 2)
		testing.expect_value(
			t,
			it_count(
				&it,
				fmt.tprintf(
					"SELECT count(*) FROM bookmarks WHERE message = %d AND time = %d",
					pinned.id,
					pinned.time,
				),
			),
			2,
		)
		saved_by_bob := it_count(
			&it,
			fmt.tprintf(
				"SELECT count(*) FROM bookmarks b JOIN accounts a ON a.id = b.account WHERE b.message = %d AND a.username IN ('bob', 'carol')",
				pinned.id,
			),
		)
		testing.expect_value(t, saved_by_bob, 2)
	}
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages WHERE flags & 2 != 0"), 1)
}

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
@(private = "file")
TEAM :: `{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`
@(private = "file")
CHANNEL :: `{"type":"channel","channel":{"team":"acme","name":"a","display_name":"a","type":"O"}}`
@(private = "file")
ROOT :: `{"type":"user","user":{"username":"root","email":"r@example.invalid","roles":"system_user system_admin","teams":[{"name":"acme","roles":"team_user","channels":[{"name":"a","roles":"channel_user"}]}]}}`

@(test)
test_import_extras_limits :: proc(t: ^testing.T) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, VERSION, TEAM, CHANNEL, ROOT)
	// More pinned and saved posts than yap keeps, one a millisecond after the
	// other, so that the oldest are the ones that go.
	extra := proto.MAX_PINS + 5
	for i in 0 ..< extra {
		append(
			&lines,
			fmt.tprintf(
				`{{"type":"post","post":{{"team":"acme","channel":"a","user":"root","message":"post %d","create_at":%d,"is_pinned":true,"flagged_by":["root","stranger"]}}}}`,
				i,
				1000 + i,
			),
		)
	}
	// A message with more different emoji than a message may have, a reaction
	// by someone who isn't imported, and a name that isn't an emoji.
	names := make([dynamic]string, context.temp_allocator)
	for e in proto.EMOJI {
		name := e.names
		if i := strings.index_byte(name, ' '); i >= 0 {
			name = name[:i]
		}
		if len(names) < proto.MAX_REACTIONS + 5 && !strings.contains_any(name, "+:") {
			append(&names, name)
		}
	}
	reactions := make([dynamic]string, context.temp_allocator)
	for name, i in names {
		append(
			&reactions,
			fmt.tprintf(`{{"user":"root","emoji_name":"%s","create_at":%d}}`, name, 5000 + i),
		)
	}
	append(&reactions, `{"user":"nobody","emoji_name":"smile","create_at":9000}`)
	append(&reactions, `{"user":"root","emoji_name":"no_such_emoji","create_at":9001}`)
	append(
		&lines,
		fmt.tprintf(
			`{{"type":"post","post":{{"team":"acme","channel":"a","user":"root","message":"many","create_at":4000,"reactions":[%s]}}}}`,
			strings.join(reactions[:], ",", context.temp_allocator),
		),
	)
	dir := export_of(t, ..lines[:])
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	run_import(t, &it)

	// The newest 1000 pins and saved posts are kept.
	testing.expect_value(t, it.im.pins, proto.MAX_PINS)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM pins"), proto.MAX_PINS)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM bookmarks"), proto.MAX_BOOKMARKS)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE flags & 2 != 0"),
		proto.MAX_PINS,
	)
	testing.expect_value(t, it_count(&it, "SELECT min(time) FROM pins"), 1005)
	testing.expect_value(t, it_count(&it, "SELECT min(time) FROM bookmarks"), 1005)
	// The message of the oldest pin is not marked as pinned any more.
	oldest, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'post 0'")
	testing.expect(t, .Pinned not_in oldest.flags)
	testing.expect_value(t, it.scan.issues[.Pins_Cut].count, 5)
	testing.expect_value(t, it.scan.issues[.Bookmarks_Cut].count, 5)
	// Saved by someone who isn't imported, once as a name.
	testing.expect_value(t, it.scan.issues[.Saved_User_Gone].count, 1)

	// At most 50 different emoji, the first 50, and the rest said.
	many, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'many'")
	testing.expect_value(
		t,
		it_count(
			&it,
			fmt.tprintf("SELECT count(DISTINCT emoji) FROM reactions WHERE message = %d", many.id),
		),
		proto.MAX_REACTIONS,
	)
	testing.expect_value(t, it.scan.issues[.Reactions_Cut].count, 5)
	testing.expect_value(t, it.scan.issues[.Reaction_User_Gone].count, 1)
	testing.expect_value(t, it.scan.issues[.Reaction_Unknown].count, 1)
}
