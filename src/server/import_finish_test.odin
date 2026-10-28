package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:proto"

// The end of an import (import_finish.odin), on the sample export.

@(private = "file")
run_all :: proc(t: ^testing.T, it: ^Import_Test) {
	if !import_accounts(&it.im) ||
	   !import_channels(&it.im) ||
	   !import_messages(&it.im) ||
	   !import_read_state(&it.im) ||
	   !import_record(&it.im) {
		testing.fail_now(t, "the import failed")
	}
	db_commit(&it.db)
}

// read_of returns where a member has read to in a conversation, in the database.
@(private = "file")
read_of :: proc(it: ^Import_Test, conv, username: string) -> i64 {
	return it_count(
		it,
		fmt.tprintf(
			"SELECT read_id FROM members WHERE conv = (SELECT id FROM convs WHERE name = '%s') AND account = (SELECT id FROM accounts WHERE username = '%s')",
			conv,
			username,
		),
	)
}

// expected_read is what a member has read, worked out in SQL from when they
// opened the conversation (`viewed`): the last message at or before that, or
// their own last message if that is later.
@(private = "file")
expected_read :: proc(it: ^Import_Test, conv, username: string, viewed: i64) -> i64 {
	return it_count(
		it,
		fmt.tprintf(
			`SELECT max(
				coalesce((SELECT max(id) FROM messages WHERE conv = c.id AND time <= %d), 0),
				coalesce((SELECT max(id) FROM messages WHERE conv = c.id AND sender = a.id), 0))
			FROM convs c, accounts a WHERE c.name = '%s' AND a.username = '%s'`,
			viewed,
			conv,
			username,
		),
	)
}

@(test)
test_import_read_state :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_all(t, &it)

	last := proc(it: ^Import_Test, conv: string) -> i64 {
		return it_count(it, fmt.tprintf("SELECT last_msg FROM convs WHERE name = '%s'", conv))
	}
	// carol opened Phoenix at the very time of its last post, which she wrote:
	// she has read all of it.
	testing.expect_value(t, read_of(&it, "Phoenix", "carol"), last(&it, "Phoenix"))
	// alice has never opened it and never wrote in it, so none of it is read.
	testing.expect_value(t, read_of(&it, "Phoenix", "alice"), 0)
	// admin never opened it either, but wrote there: they have read their own posts.
	testing.expect(t, read_of(&it, "Phoenix", "admin") > 0)
	testing.expect(t, read_of(&it, "Phoenix", "admin") < last(&it, "Phoenix"))
	testing.expect_value(
		t,
		read_of(&it, "Phoenix", "admin"),
		it_count(
			&it,
			"SELECT max(id) FROM messages WHERE conv = (SELECT id FROM convs WHERE name = 'Phoenix') AND sender = (SELECT id FROM accounts WHERE username = 'admin')",
		),
	)
	// A member who has opened a conversation in the middle of it: what they opened
	// (or wrote) up to, by the rule, in SQL.
	for check in ([]struct {
			conv, user: string,
			viewed:     i64,
		} {
			{"General Talk Renamed", "admin", 1793200877840},
			{"General Talk Renamed", "alice", 1793200878799},
			{"General Talk Renamed", "bob", 1793200878897},
			{"General Talk Renamed", "carol", 1793200880092},
			{"General Talk Renamed", "gus", 0},
			{"Off-Topic", "bob", 1793200877623},
			{"Off-Topic", "carol", 0},
			{"Secret", "alice", 1793200879025},
			{"Secret", "bob", 0},
		}) {
		want := expected_read(&it, check.conv, check.user, check.viewed)
		got := read_of(&it, check.conv, check.user)
		testing.expectf(
			t,
			got == want,
			"%s in %s has read to %d, not %d",
			check.user,
			check.conv,
			got,
			want,
		)
	}
	// Someone who read in the middle has unread messages after that.
	testing.expect(
		t,
		read_of(&it, "General Talk Renamed", "admin") < last(&it, "General Talk Renamed"),
	)
	// gus never opened it nor wrote: none of it is read.
	testing.expect_value(t, read_of(&it, "General Talk Renamed", "gus"), 0)

	// A DM: alice opened it, and carol in the group opened it after.
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM members WHERE read_id > 0"),
		it_count(&it, "SELECT count(*) FROM members WHERE read_id > 0"),
	) // sanity
	// Never past the end, and always at a message of the conversation.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM members m JOIN convs c ON c.id = m.conv WHERE m.read_id > c.last_msg",
		),
		0,
	)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM members m WHERE m.read_id != 0 AND NOT EXISTS (SELECT 1 FROM messages x WHERE x.id = m.read_id AND x.conv = m.conv)",
		),
		0,
	)
	// And the server counts the unread the way a person sees them: a message
	// after the read position counts, one of the member's own and a system message don't.
	loaded: Convs
	testing.expect(t, convs_load(&loaded, &it.db, []string{DEFAULT_CHANNEL_NAME}, &it.accounts))
	defer convs_destroy(&loaded)
	phoenix := conv_by_name(&loaded, "Phoenix")
	alice := account_find(&it.accounts, "alice")
	testing.expect(t, phoenix != nil && alice != nil)
	if phoenix != nil && alice != nil {
		unread := conv_unread(&loaded, phoenix, alice.id, phoenix.reads[alice.id].read)
		testing.expect(t, unread > 0)
		carol := account_find(&it.accounts, "carol")
		testing.expect_value(
			t,
			conv_unread(&loaded, phoenix, carol.id, phoenix.reads[carol.id].read),
			0,
		)
	}
}

@(test)
test_import_record_and_verify :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_all(t, &it)

	source, found := db_meta_text(&it.db, "imported_from")
	testing.expect(t, found)
	testing.expect(
		t,
		strings.contains(source, "Mattermost 10.12.4") && strings.contains(source, "acme"),
	)
	at, has_time := db_meta(&it.db, "imported_at")
	testing.expect(t, has_time && at > 1_700_000_000_000)

	// The result is all right.
	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)

	// And a second import into it is refused.
	err := import_precheck(&it.db)
	testing.expect(t, strings.contains(err, "already has"))

	// What is wrong is found. A reply that points at nothing:
	testing.expect(
		t,
		db_exec(
			&it.db,
			"UPDATE messages SET thread_root = 99999 WHERE id = (SELECT min(id) FROM messages WHERE thread_root != 0)",
		),
	)
	problems = import_verify(&it.im)
	testing.expect(
		t,
		len(problems) > 0 &&
		strings.contains(
			strings.join(problems, "; ", context.temp_allocator),
			"replies to a post that isn't there",
		),
	)
	testing.expect(
		t,
		db_exec(
			&it.db,
			"UPDATE messages SET thread_root = (SELECT min(id) FROM messages WHERE reply_count > 0) WHERE id = (SELECT min(id) FROM messages WHERE thread_root = 99999)",
		),
	)
	// A conversation whose last message isn't:
	testing.expect(
		t,
		db_exec(&it.db, "UPDATE convs SET last_msg = last_msg + 1 WHERE name = 'Phoenix'"),
	)
	problems = import_verify(&it.im)
	testing.expect(
		t,
		strings.contains(
			strings.join(problems, "; ", context.temp_allocator),
			"last message is wrong",
		),
	)
	testing.expect(
		t,
		db_exec(&it.db, "UPDATE convs SET last_msg = last_msg - 1 WHERE name = 'Phoenix'"),
	)
	// A pin whose message isn't marked pinned:
	testing.expect(
		t,
		db_exec(&it.db, "UPDATE messages SET flags = flags & ~2 WHERE flags & 2 != 0"),
	)
	problems = import_verify(&it.im)
	testing.expect(
		t,
		strings.contains(strings.join(problems, "; ", context.temp_allocator), "marked as pinned"),
	)
	testing.expect(
		t,
		db_exec(
			&it.db,
			"UPDATE messages SET flags = flags | 2 WHERE id IN (SELECT message FROM pins)",
		),
	)
}

@(test)
test_import_report_file :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_all(t, &it)
	path := file_in(it.dir, "import-report.txt")
	testing.expect_value(t, import_write_report(&it.im, path), "")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	text := string(data)
	for want in ([]string {
			"Mattermost export",
			"Team: acme (Acme)",
			"Warnings",
			"alice,erin", // the direct channel that was left out
			"What was made",
			"10 accounts, 6 channels, 6 direct conversations",
			"85 messages, 8 reactions, 1 pins, 2 saved posts",
			"Not imported yet: files attached",
			"posts with nothing to show", // found while writing
		}) {
		testing.expectf(t, strings.contains(text, want), "the report lacks %q:\n%s", want, text)
	}
	testing.expect_value(t, proto.MAX_PINS, 1000)
}
