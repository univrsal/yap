package server

import "core:fmt"
import "core:testing"

import "common:proto"

@(private = "file")
it_all :: proc(t: ^testing.T, it: ^Import_Test) {
	if !import_accounts(&it.im) || !import_channels(&it.im) || !import_messages(&it.im) {
		testing.fail_now(t, "the import failed")
	}
	db_commit(&it.db)
}

// it_message reads the message that an id selecting query finds.
@(private = "file")
it_message :: proc(it: ^Import_Test, sql: string) -> (m: proto.Message, ok: bool) {
	id, rc := db_pragma_int(&it.db, sql)
	if rc != 0 || id == 0 {
		return
	}
	q := db_query(&it.db, .Msg_By_Id, id)
	row, stepped := db_step(&it.db, q)
	if !stepped || !row {
		return
	}
	m = msg_of_row(q)
	// The strings are the temp allocator's, which the next call may free.
	m.text = fmt.tprint(m.text)
	return m, true
}

@(test)
test_import_messages :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	// Something in the temp allocator from before, such as the path of the password
	// file, which the import must not free.
	kept := fmt.tprintf("%s/%s", "passwords", "csv")
	it_all(t, &it)
	testing.expect_value(t, kept, "passwords/csv")

	// 85 of the 88 posts: left out are the bot's greeting, the change of a
	// purpose in a channel that has a header, and a post with only a file.
	testing.expect_value(t, it.im.messages, 85)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages"), 85)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages WHERE kind = 3"), 48) // system
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages WHERE kind = 0"), 37)
	testing.expect_value(t, it.scan.issues[.Post_Empty].count, 1)
	testing.expect_value(t, it.scan.issues[.System_Skipped].count, 0)
	testing.expect_value(t, it.scan.issues[.Post_Failed].count, 0)
	testing.expect_value(t, it.scan.issues[.Thread_Root_Missing].count, 0)

	// Ids follow time, across all conversations.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM messages a JOIN messages b ON b.id = a.id + 1 WHERE b.time < a.time",
		),
		0,
	)
	// The times are Mattermost's, not the import's.
	testing.expect_value(t, it_count(&it, "SELECT min(time) FROM messages"), 1793200875374)
	testing.expect_value(t, it_count(&it, "SELECT max(time) FROM messages"), 1793200880092)

	// Three threads with five replies; the counts are the server's own.
	testing.expect_value(t, len(it.im.roots), 3)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE thread_root != 0"),
		5,
	)
	testing.expect_value(t, it_count(&it, "SELECT sum(reply_count) FROM messages"), 5)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages WHERE flags & 4 != 0"), 3)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM messages r JOIN messages p ON p.id = r.thread_root WHERE r.conv = p.conv AND r.id > p.id",
		),
		5,
	)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM messages p WHERE p.reply_count > 0 AND p.last_reply = (SELECT max(id) FROM messages WHERE thread_root = p.id)",
		),
		3,
	)
	// One message was edited.
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages WHERE edited != 0"), 1)

	// Each system message says who did what to whom.
	added, ok := it_message(
		&it,
		"SELECT id FROM messages WHERE kind = 3 AND text = '18' AND file_size = (SELECT id FROM accounts WHERE username = 'bob') LIMIT 1",
	)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, added.system, u8(proto.Conv_System.Added))
		testing.expect_value(t, it.accounts.by_id[added.sender].username, "admin")
		testing.expect_value(
			t,
			it.accounts.by_id[proto.Account_Id(added.system_arg)].username,
			"bob",
		)
	}
	renamed, found := it_message(&it, "SELECT id FROM messages WHERE kind = 3 AND text LIKE '20%'")
	testing.expect(t, found)
	if found {
		old, new := proto.system_change(renamed.text)
		testing.expect_value(t, old, "General Talk")
		testing.expect_value(t, new, "General Talk Renamed")
		testing.expect_value(t, it.accounts.by_id[renamed.sender].username, "alice")
	}
	// Someone joining the team is a message in the home channel.
	joined, found2 := it_message(
		&it,
		"SELECT id FROM messages WHERE kind = 3 AND text = '26' LIMIT 1",
	)
	testing.expect(t, found2)
	if found2 {
		testing.expect_value(t, joined.conv, it.convs.home.id)
	}
	// A message is in its conversation, from its author.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM messages m JOIN convs c ON c.id = m.conv WHERE c.kind != 0",
		),
		8, // the direct posts, less the greeting that a bot made
	)

	// Every conversation knows its last message, in the database and in memory.
	for _, conv in it.convs.by_id {
		last := it_count(
			&it,
			fmt.tprintf("SELECT coalesce(max(id), 0) FROM messages WHERE conv = %d", conv.id),
		)
		testing.expectf(
			t,
			i64(conv.last_msg) == last,
			"%s: %d, not %d",
			conv.name,
			conv.last_msg,
			last,
		)
		stored := it_count(&it, fmt.tprintf("SELECT last_msg FROM convs WHERE id = %d", conv.id))
		testing.expectf(t, stored == last, "%s stored %d, not %d", conv.name, stored, last)
	}
	// A server can take it from here: the search index has the words, and the
	// conversations load.
	testing.expect(t, it_count(&it, "SELECT count(*) FROM messages_fts") > 0)
	loaded: Convs
	testing.expect(t, convs_load(&loaded, &it.db, []string{DEFAULT_CHANNEL_NAME}, &it.accounts))
	defer convs_destroy(&loaded)
	testing.expect(t, loaded.home.last_msg != 0 && loaded.home.last_time != 0)
}

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
@(private = "file")
TEAM :: `{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`
@(private = "file")
ROOT :: `{"type":"user","user":{"username":"root","email":"r@example.invalid","roles":"system_user system_admin","teams":[{"name":"acme","roles":"team_user","channels":[{"name":"a","roles":"channel_user"},{"name":"b","roles":"channel_user"}]}]}}`

@(private = "file")
channel :: proc(name, type: string) -> string {
	return fmt.tprintf(
		`{{"type":"channel","channel":{{"team":"acme","name":"%s","display_name":"%s","type":"%s"}}}}`,
		name,
		name,
		type,
	)
}

@(private = "file")
post :: proc(channel, user, message: string, at: int, extra := "") -> string {
	return fmt.tprintf(
		`{{"type":"post","post":{{"team":"acme","channel":"%s","user":"%s","message":"%s","create_at":%d%s}}}}`,
		channel,
		user,
		message,
		at,
		extra,
	)
}

@(test)
test_import_message_order :: proc(t: ^testing.T) {
	// Posts of two channels out of order in the file, a thread whose reply is
	// listed (and timed) before the first post of another, and a reply that is
	// timed before its first post, which is not what a Mattermost does but
	// mustn't give a thread that points forward.
	reply := proc(user, message: string, at: int) -> string {
		return fmt.tprintf(`{{"user":"%s","message":"%s","create_at":%d}}`, user, message, at)
	}
	dir := export_of(
		t,
		VERSION,
		TEAM,
		channel("a", "O"),
		channel("b", "O"),
		ROOT,
		post("b", "root", "b-third", 3000),
		post(
			"a",
			"root",
			"a-second",
			2000,
			fmt.tprintf(
				`,"replies":[%s,%s]`,
				reply("root", "reply-late", 5000),
				reply("root", "reply-early", 1000),
			),
		),
		post("a", "root", "a-first", 1500),
		post("b", "root", "b-fourth", 4000),
	)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	it_all(t, &it)

	// In time order: a-first (1500), a-second (2000), reply-early which is no
	// earlier than its post (2000), b-third, b-fourth, reply-late.
	want := []string{"a-first", "a-second", "reply-early", "b-third", "b-fourth", "reply-late"}
	for text, i in want {
		m, ok := it_message(&it, fmt.tprintf("SELECT id FROM messages WHERE id = %d", i + 1))
		testing.expect(t, ok)
		testing.expectf(t, m.text == text, "message %d is %q, not %q", i + 1, m.text, text)
	}
	early, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'reply-early'")
	late, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'reply-late'")
	second, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'a-second'")
	testing.expect_value(t, early.thread_root, second.id)
	testing.expect_value(t, late.thread_root, second.id)
	testing.expect_value(t, second.reply_count, 2)
	testing.expect_value(t, second.last_reply, late.id)
	testing.expect(t, .Has_Thread in second.flags)
	// Its own time is kept, whatever the order was made from.
	testing.expect_value(t, early.time, proto.Unix_Ms(1000))
}

@(test)
test_import_message_cases :: proc(t: ^testing.T) {
	dir := export_of(
		t,
		VERSION,
		TEAM,
		channel("a", "P"),
		ROOT,
		// A first post with only a file, which isn't imported yet, with a reply:
		// the reply is a message of its own.
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","message":"","create_at":100,"replies":[{"user":"root","message":"answer","create_at":200}]}}`,
		// An author that is gone.
		post("a", "ghost", "from nobody", 300),
		// Privacy changes in a language that isn't English: private again, public, private.
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","type":"system_change_chan_privacy","message":"Der Kanal ist jetzt privat.","props":{"username":"root"},"create_at":400}}`,
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","type":"system_change_chan_privacy","message":"Der Kanal ist jetzt oeffentlich.","props":{"username":"root"},"create_at":500}}`,
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","type":"system_change_chan_privacy","message":"Der Kanal ist jetzt privat.","props":{"username":"root"},"create_at":600}}`,
		// Something done to someone who isn't imported.
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","type":"system_add_to_channel","message":"x","props":{"addedUsername":"stranger"},"create_at":700}}`,
		// Control characters and a very long message.
		post("a", "root", "tab\\there\\u0007", 800),
	)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	it_all(t, &it)

	// The reply stands alone.
	answer, ok := it_message(&it, "SELECT id FROM messages WHERE text = 'answer'")
	testing.expect(t, ok)
	testing.expect_value(t, answer.thread_root, proto.Msg_Id(0))
	testing.expect_value(t, it.scan.issues[.Thread_Root_Missing].count, 1)
	testing.expect_value(t, it.scan.issues[.Post_Empty].count, 1)

	// The author who is gone is shown as a deleted account.
	nobody, found := it_message(&it, "SELECT id FROM messages WHERE text = 'from nobody'")
	testing.expect(t, found)
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT flags FROM accounts WHERE id = %d", nobody.sender)),
		i64(transmute(u8)proto.Account_Flags{.Deleted}),
	)

	// The directions come from the channel being private now: private, public, private.
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE kind = 3 AND text = '22'"),
		2,
	)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE kind = 3 AND text = '23'"),
		1,
	)

	// A system post about someone who isn't imported is left out, and said.
	testing.expect_value(t, it.scan.issues[.System_Skipped].count, 1)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE kind = 3 AND text = '18'"),
		0,
	)
	// Control characters are cleaned the way a posted message is.
	cleaned, found3 := it_message(&it, "SELECT id FROM messages WHERE text LIKE 'tab%'")
	testing.expect(t, found3)
	testing.expect_value(t, cleaned.text, "tab here")
}
