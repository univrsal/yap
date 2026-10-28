package server

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import "common:proto"
import "mattermost"

// The end of an import (docs/design/mattermost-import.md, 7g): where each
// member has read to, a record of what was imported, a check of the result,
// and the report that is kept.

// What an import doesn't bring yet, which the report says. It goes when steps
// 8 to 10 are done.
IMPORT_NOT_YET :: `Not imported yet: the links and mentions in messages (@name, ~channel), and the cards of bots and webhooks.`

@(private = "file")
Reader :: struct {
	account: proto.Account_Id,
	viewed:  i64, // last_viewed_at
}

// import_read_state sets how far each member has read of each conversation.
//
// Mattermost says when a member last opened a channel, not what they had read,
// so a member has read the messages up to then: the last message at or before
// that time. A member has also read what they wrote themselves (as yap counts a
// poster as having read up to their message), if that is later. A member who
// never opened a conversation and never wrote in it has read nothing, which
// leaves all of it unread, as in Mattermost.
import_read_state :: proc(im: ^Importer) -> bool {
	s := im.scan
	// Who opened what when, by conversation.
	viewed := make(map[proto.Conv_Id][dynamic]Reader, context.temp_allocator)
	add :: proc(
		viewed: ^map[proto.Conv_Id][dynamic]Reader,
		conv: ^Conv,
		account: proto.Account_Id,
		at: i64,
	) {
		list := viewed[conv.id]
		list.allocator = context.temp_allocator
		append(&list, Reader{account, at})
		viewed[conv.id] = list
	}
	for acc in s.plan.accounts {
		if acc.bot || acc.author_only {
			continue
		}
		u := s.users[s.user_index[acc.mm_name]]
		for t in u.teams {
			for m in t.channels {
				if index, found := s.channel_index[m.name]; found {
					add(&viewed, im.channels[index], im.ids[acc.mm_name], m.last_viewed_at)
				}
			}
		}
	}
	for d, i in s.directs {
		for p in d.participants {
			add(&viewed, im.direct_list[i], im.ids[p.username], p.last_viewed_at)
		}
	}

	all := make([dynamic]^Conv, 0, len(im.channels) + len(im.direct_list), context.temp_allocator)
	append(&all, ..im.channels)
	append(&all, ..im.direct_list)
	progress := progress_start("setting what people have read")
	for conv, n in all {
		progress_update(&progress, i64(n), i64(len(all)))
		if !import_read_conv(im, conv, viewed[conv.id][:]) {
			return false
		}
	}
	progress.done = i64(len(all))
	progress_finish(&progress)
	return true
}

// import_read_conv sets what each member of one conversation has read, from
// when each opened it. What it needs is let go of at the end, and nothing that
// was in the temp allocator before is.
@(private = "file")
import_read_conv :: proc(im: ^Importer, conv: ^Conv, readers: []Reader) -> bool {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	if conv.last_msg == 0 {
		return true
	}
	// The conversation's messages in the order of their ids, which is the order
	// of their times.
	ids := make([dynamic]proto.Msg_Id, 0, 64, context.temp_allocator)
	times := make([dynamic]i64, 0, 64, context.temp_allocator)
	own := make(map[proto.Account_Id]proto.Msg_Id, context.temp_allocator)
	q := db_query(im.db, .Msg_Times_Of, i64(conv.id))
	for {
		row, stepped := db_step(im.db, q)
		if !stepped {
			log.errorf("could not read the messages of %s", conv.name)
			return false
		}
		if !row {
			break
		}
		id := proto.Msg_Id(db_col_int(q, 0))
		append(&ids, id)
		append(&times, db_col_int(q, 1))
		own[proto.Account_Id(db_col_int(q, 2))] = id
	}
	opened := make(map[proto.Account_Id]i64, context.temp_allocator)
	for r in readers {
		opened[r.account] = max(opened[r.account], r.viewed)
	}
	for member in conv.members {
		read := own[member] or_else 0
		if at := opened[member] or_else 0; at > 0 {
			// The first message after that time, and so the one before it.
			after, _ := slice.binary_search_by(times[:], at, proc(t, at: i64) -> slice.Ordering {
				return .Less if t <= at else .Greater
			})
			if after > 0 {
				read = max(read, ids[after - 1])
			}
		}
		if read != 0 && !conv_set_read(im.convs, conv, member, read) {
			log.errorf("could not set what %d has read of %s", member, conv.name)
			return false
		}
	}
	return true
}

// import_record notes in the database where it came from, so that it can be told
// later that it was imported.
import_record :: proc(im: ^Importer) -> bool {
	s := im.scan
	source := fmt.tprintf("Mattermost %s, the team %s", s.info.version, s.team)
	return(
		db_meta_set_text(im.db, "imported_from", source) &&
		db_meta_set(im.db, "imported_at", unix_ms()) \
	)
}

// import_verify checks the result as the server will meet it: that nothing
// points at something that isn't there, that the numbers that were worked out
// agree with the messages, and that the server can load it. It returns what is
// wrong (nothing when it is all well), as text from the temp allocator.
import_verify :: proc(im: ^Importer) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	Check :: struct {
		what: string,
		sql:  string, // answers how many things are wrong
	}
	checks := [?]Check {
		{
			"messages in a conversation that isn't there",
			"SELECT count(*) FROM messages WHERE conv NOT IN (SELECT id FROM convs)",
		},
		{
			"messages by someone who isn't there",
			"SELECT count(*) FROM messages WHERE sender NOT IN (SELECT id FROM accounts)",
		},
		{
			"replies to a post that isn't there, or in another conversation",
			"SELECT count(*) FROM messages r LEFT JOIN messages p ON p.id = r.thread_root WHERE r.thread_root != 0 AND (p.id IS NULL OR p.conv != r.conv OR p.id > r.id)",
		},
		{
			"threads whose count of replies is wrong",
			"SELECT count(*) FROM (SELECT thread_root t, count(*) c FROM messages WHERE thread_root != 0 GROUP BY thread_root) g JOIN messages p ON p.id = g.t WHERE p.reply_count != g.c OR p.flags & 4 = 0",
		},
		{
			"text messages that the search doesn't know (or the other way round)",
			"SELECT abs((SELECT count(*) FROM messages WHERE kind = 0 AND text IS NOT NULL) - (SELECT count(*) FROM messages_fts_docsize))",
		},
		{
			"files of messages that aren't in the store, or messages marked as having files that have none",
			"SELECT (SELECT count(*) FROM attachments WHERE blob IS NOT NULL AND blob NOT IN (SELECT id FROM blobs)) + (SELECT count(*) FROM attachments WHERE msg NOT IN (SELECT id FROM messages)) + (SELECT count(*) FROM messages m WHERE m.flags & 16 != 0 AND NOT EXISTS (SELECT 1 FROM attachments a WHERE a.msg = m.id)) + (SELECT count(*) FROM messages m WHERE m.flags & 16 = 0 AND EXISTS (SELECT 1 FROM attachments a WHERE a.msg = m.id))",
		},
		{
			"messages whose id is out of the order of their times",
			"SELECT count(*) FROM messages a JOIN messages b ON b.id = a.id + 1 WHERE b.time < a.time AND a.conv = b.conv",
		},
		{
			"members who aren't accounts or conversations",
			"SELECT count(*) FROM members WHERE account NOT IN (SELECT id FROM accounts) OR conv NOT IN (SELECT id FROM convs)",
		},
		{
			"members who have read past the end of their conversation",
			"SELECT count(*) FROM members m JOIN convs c ON c.id = m.conv WHERE m.read_id > c.last_msg",
		},
		{
			"conversations whose last message is wrong",
			"SELECT count(*) FROM convs c WHERE c.last_msg != coalesce((SELECT max(id) FROM messages WHERE conv = c.id), 0)",
		},
		{
			"reactions, pins or saved posts of a message that isn't there",
			"SELECT (SELECT count(*) FROM reactions WHERE message NOT IN (SELECT id FROM messages)) + (SELECT count(*) FROM pins WHERE message NOT IN (SELECT id FROM messages)) + (SELECT count(*) FROM bookmarks WHERE message NOT IN (SELECT id FROM messages))",
		},
		{
			"pins and messages marked as pinned that don't agree",
			"SELECT (SELECT count(*) FROM pins p JOIN messages m ON m.id = p.message WHERE m.flags & 2 = 0) + (SELECT count(*) FROM messages m WHERE m.flags & 2 != 0 AND NOT EXISTS (SELECT 1 FROM pins p WHERE p.message = m.id))",
		},
	}
	for check in checks {
		n, rc := db_pragma_int(im.db, check.sql)
		if rc != 0 {
			append(&problems, fmt.tprintf("could not check %s", check.what))
		} else if n != 0 {
			append(&problems, fmt.tprintf("%d %s", n, check.what))
		}
	}
	// Every stored file is there to be read.
	if missing := import_missing_blobs(im); missing > 0 {
		append(&problems, fmt.tprintf("%d stored files that aren't on disk", missing))
	}
	// A row from the check means a reference to something that isn't there.
	if _, rc := db_pragma_int(im.db, "PRAGMA foreign_key_check"); rc == 0 {
		append(&problems, "rows that refer to something that isn't there (foreign key check)")
	}

	// The server loads the accounts and conversations when it starts.
	accounts: Accounts
	if !accounts_load(&accounts, im.db) {
		append(&problems, "the accounts can't be loaded")
		return problems[:]
	}
	defer accounts_destroy(&accounts)
	convs: Convs
	if !convs_load(&convs, im.db, []string{DEFAULT_CHANNEL_NAME}, &accounts) {
		append(&problems, "the conversations can't be loaded")
		return problems[:]
	}
	defer convs_destroy(&convs)
	want_accounts := len(im.scan.plan.accounts) + len(im.scan.authors_gone)
	if len(accounts.by_id) != want_accounts {
		append(
			&problems,
			fmt.tprintf(
				"%d accounts load, not the %d that were made",
				len(accounts.by_id),
				want_accounts,
			),
		)
	}
	// The conversations that were made: the channels, the direct conversations
	// (two direct channels of the same people are one) and the home channel,
	// which is one of the channels unless the export had none for it.
	made := make(map[^Conv]bool, context.temp_allocator)
	for conv in im.channels {
		made[conv] = true
	}
	for conv in im.direct_list {
		made[conv] = true
	}
	made[im.convs.home] = true
	if len(convs.by_id) != len(made) {
		append(
			&problems,
			fmt.tprintf(
				"%d conversations load, not the %d that were made",
				len(convs.by_id),
				len(made),
			),
		)
	}
	if convs.home == nil || convs.home.id != im.convs.home.id {
		append(&problems, "the home channel isn't the one that was made")
	}
	return problems[:]
}

// import_write_report writes what an import found and did to a file: the
// report of the scan and plan (including what the writing steps found), what
// was made, and what isn't imported yet.
import_write_report :: proc(im: ^Importer, path: string) -> (err: string) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	w := strings.to_writer(&b)
	mattermost.report_write(im.scan, w)
	io.write_string(w, "\nWhat was made\n")
	io.write_string(
		w,
		fmt.tprintf(
			"  %d accounts, %d channels, %d direct conversations\n",
			len(im.scan.plan.accounts) + len(im.scan.authors_gone),
			len(im.channels),
			len(im.direct_list),
		),
	)
	io.write_string(
		w,
		fmt.tprintf(
			"  %d messages, %d reactions, %d pins, %d saved posts\n",
			im.messages,
			im.reactions,
			im.pins,
			im.bookmarks,
		),
	)
	if im.csv != "" {
		io.write_string(w, fmt.tprintf("  the passwords are in %s\n", im.csv))
	}
	io.write_string(w, "\n")
	io.write_string(w, IMPORT_NOT_YET)
	io.write_string(w, "\n")
	if write_err := os.write_entire_file(path, strings.to_string(b)); write_err != nil {
		return fmt.tprintf("could not write %s: %v", path, write_err)
	}
	return ""
}

// import_missing_blobs counts the blobs of the database whose file isn't in the
// store.
@(private = "file")
import_missing_blobs :: proc(im: ^Importer) -> (missing: int) {
	q := db_stmt(im.db, .Blob_Hashes)
	for {
		row, ok := db_step(im.db, q)
		if !ok || !row {
			break
		}
		sum: [BLOB_HASH_SIZE]u8
		if !db_col_into(q, 0, sum[:]) || !os.exists(blob_path(im.blobs, sum)) {
			missing += 1
		}
	}
	return
}
