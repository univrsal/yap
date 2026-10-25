package server

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Tests of the database and the blob store. Most run on an in-memory database.
// The ones that are about what is stored on disk get a folder of their own under
// the system's temporary folder.
//
// The test runner counts an error in the log as a failure, so where a test makes
// something fail on purpose, it does so with the log switched off.

@(private = "file")
pragma :: proc(t: ^testing.T, db: ^DB, sql: string) -> i64 {
	value, rc := db_pragma_int(db, sql)
	testing.expect_value(t, rc, 0)
	return value
}

@(test)
test_db_memory :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)

	testing.expect_value(t, pragma(t, &db, "PRAGMA user_version"), SCHEMA_VERSION)
	testing.expect_value(t, pragma(t, &db, "PRAGMA foreign_keys"), 1)
	created, found := db_meta(&db, "created")
	testing.expect(t, found)
	testing.expect(t, created > 0 && created <= unix_ms())

	_, found = db_meta(&db, "nothing")
	testing.expect(t, !found)
	testing.expect(t, db_meta_set(&db, "answer", 41))
	testing.expect(t, db_meta_set(&db, "answer", 42))
	answer: i64
	answer, found = db_meta(&db, "answer")
	testing.expect(t, found)
	testing.expect_value(t, answer, 42)
}

@(test)
test_db_transaction :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)

	// The writes of a turn form one transaction, which stays open until it is
	// committed.
	testing.expect(t, !db.in_tx)
	testing.expect(t, db_meta_set(&db, "a", 1))
	testing.expect(t, db.in_tx)
	testing.expect(t, db_meta_set(&db, "b", 2))
	db_commit(&db)
	testing.expect(t, !db.in_tx)
	// Committing when no transaction is open does nothing.
	db_commit(&db)

	b, found := db_meta(&db, "b")
	testing.expect(t, found)
	testing.expect_value(t, b, 2)
}

@(test)
test_db_file :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)

	created: i64
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		// The file is set up so that purging can give space back, and for
		// write-ahead logging.
		testing.expect_value(t, pragma(t, &db, "PRAGMA auto_vacuum"), 2)
		testing.expect_value(t, pragma(t, &db, "PRAGMA synchronous"), 1)
		testing.expect_value(t, pragma(t, &db, "PRAGMA wal_autocheckpoint"), 0)
		created, _ = db_meta(&db, "created")
		testing.expect(t, db_meta_set(&db, "kept", 7))
		db_commit(&db)
		testing.expect(t, db.log_pages > 0)

		// Another process that wants the same file is told that it is in use.
		{
			context.logger = log.nil_logger()
			other: DB
			testing.expect(t, !db_open(&other, path))
		}

		db_checkpoint(&db)
		testing.expect_value(t, db.log_pages, 0)
		wal, err := os.stat(file_in(dir, DB_FILE + "-wal"), context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, wal.size, 0)
	}

	// When opened again it is the same database, and nothing is created a second
	// time.
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		testing.expect_value(t, pragma(t, &db, "PRAGMA user_version"), SCHEMA_VERSION)
		again, _ := db_meta(&db, "created")
		testing.expect_value(t, again, created)
		kept, found := db_meta(&db, "kept")
		testing.expect(t, found)
		testing.expect_value(t, kept, 7)
	}
}

@(test)
test_db_uncommitted :: proc(t: ^testing.T) {
	// What was committed survives if the server stops without closing the
	// database, and what wasn't committed is lost.
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(t, db_meta_set(&db, "committed", 1))
		db_commit(&db)
		testing.expect(t, db_meta_set(&db, "open", 1))
		// This is as close to the server being killed as a test can get: the
		// connection is closed without a commit.
		testing.expect(t, db_exec(&db, "ROLLBACK"))
		db.in_tx = false
		db_close(&db)
	}
	db: DB
	testing.expect(t, db_open(&db, path))
	defer db_close(&db)
	_, found := db_meta(&db, "committed")
	testing.expect(t, found)
	_, found = db_meta(&db, "open")
	testing.expect(t, !found)
}

@(test)
test_db_newer :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(t, db_exec(&db, "PRAGMA user_version = 9999"))
		db_close(&db)
	}
	context.logger = log.nil_logger()
	db: DB
	testing.expect(t, !db_open(&db, path))
}

@(test)
test_db_before_baseline :: proc(t: ^testing.T) {
	// A database from before the baseline, other than version 28, is refused.
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(t, db_exec(&db, "PRAGMA user_version = 27"))
		db_close(&db)
	}
	context.logger = log.nil_logger()
	db: DB
	testing.expect(t, !db_open(&db, path))
}

@(test)
test_db_upgrade_28 :: proc(t: ^testing.T) {
	// A database at version 28 still has messages.blob and its index. It is
	// brought to the baseline without them, and keeps its messages, what
	// refers to them, the search index and the id counter.
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(
			t,
			db_exec(
				&db,
				`
				ALTER TABLE messages ADD COLUMN blob INTEGER REFERENCES blobs(id);
				CREATE INDEX messages_blob ON messages(blob) WHERE blob IS NOT NULL;
				INSERT INTO accounts (username, display, pw_hash, pw_salt, pw_params, created)
					VALUES ('alice', 'Alice', x'00', x'00', 1, 1);
				INSERT INTO convs (kind, name, created) VALUES (0, 'lobby', 1);
				INSERT INTO messages (conv, sender, time, kind, text) VALUES (1, 1, 1, 0, 'hello there');
				INSERT INTO messages (conv, sender, time, kind, text) VALUES (1, 1, 2, 0, 'purged later');
				DELETE FROM messages WHERE id = 2;
				INSERT INTO pins (conv, message, by, time) VALUES (1, 1, 1, 3);
				PRAGMA user_version = 28;
				`,
			),
		)
		testing.expect(t, db_meta_set(&db, "kept", 5))
		db_commit(&db)
		db_close(&db)
	}

	db: DB
	testing.expect(t, db_open(&db, path))
	defer db_close(&db)
	testing.expect_value(t, pragma(t, &db, "PRAGMA user_version"), SCHEMA_VERSION)
	testing.expect_value(t, pragma(t, &db, "PRAGMA foreign_keys"), 1)
	testing.expect_value(
		t,
		pragma(t, &db, "SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'blob'"),
		0,
	)
	testing.expect_value(
		t,
		pragma(
			t,
			&db,
			"SELECT count(*) FROM sqlite_master WHERE name IN ('messages_blob', 'messages_old')",
		),
		0,
	)
	testing.expect_value(t, pragma(t, &db, "SELECT count(*) FROM pragma_foreign_key_check"), 0)
	testing.expect_value(t, pragma(t, &db, "SELECT count(*) FROM messages"), 1)
	testing.expect_value(t, pragma(t, &db, "SELECT message FROM pins"), 1)
	testing.expect_value(
		t,
		pragma(t, &db, "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'hello'"),
		1,
	)
	kept, found := db_meta(&db, "kept")
	testing.expect(t, found)
	testing.expect_value(t, kept, 5)

	// The id of the purged message isn't given out again, and the triggers
	// are back.
	testing.expect(
		t,
		db_exec(
			&db,
			"INSERT INTO messages (conv, sender, time, kind, text) VALUES (1, 1, 4, 0, 'new one')",
		),
	)
	testing.expect_value(t, pragma(t, &db, "SELECT max(id) FROM messages"), 3)
	testing.expect_value(
		t,
		pragma(t, &db, "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'new'"),
		3,
	)
}

@(test)
test_db_not_a_database :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	testing.expect(
		t,
		os.write_entire_file(path, "this is no database, only a text file of some length") == nil,
	)
	context.logger = log.nil_logger()
	db: DB
	testing.expect(t, !db_open(&db, path))
}

@(private = "file")
Test_Store :: struct {
	db:    DB,
	blobs: Blob_Store,
	dir:   string,
}

@(private = "file")
store_open :: proc(t: ^testing.T, ts: ^Test_Store) {
	ts.dir = test_dir(t)
	testing.expect(t, db_open(&ts.db, DB_MEMORY))
	testing.expect(t, blob_store_open(&ts.blobs, &ts.db, file_in(ts.dir, BLOBS_DIR)))
}

@(private = "file")
store_close :: proc(ts: ^Test_Store) {
	blob_store_close(&ts.blobs)
	db_close(&ts.db)
	remove_tree(ts.dir)
}

@(test)
test_blob_put_and_read :: proc(t: ^testing.T) {
	ts: Test_Store
	store_open(t, &ts)
	defer store_close(&ts)
	bs := &ts.blobs

	data := make([]u8, 100_000, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 7)
	}
	id, ok := blob_put(bs, .File, data, 640, 480)
	testing.expect(t, ok)
	testing.expect(t, id != 0)

	b, found := blob_get(bs, id)
	testing.expect(t, found)
	testing.expect_value(t, b.id, id)
	testing.expect_value(t, b.size, len(data))
	testing.expect_value(t, b.kind, Blob_Kind.File)
	testing.expect_value(t, b.width, 640)
	testing.expect_value(t, b.height, 480)
	testing.expect_value(t, b.hash, blob_hash(data))
	testing.expect(t, b.created > 0)

	// The file is at the path its hash determines, and no other files are left
	// next to it.
	path := blob_path(bs, b.hash)
	testing.expect(t, os.exists(path))
	files, err := os.read_directory_by_path(os.dir(path), -1, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(files), 1)

	content, read := blob_read(bs, id, context.temp_allocator)
	testing.expect(t, read)
	testing.expect(t, slice.equal(content, data))

	by_hash, has := blob_find(bs, b.hash)
	testing.expect(t, has)
	testing.expect_value(t, by_hash, id)
}

@(test)
test_blob_same_content_once :: proc(t: ^testing.T) {
	ts: Test_Store
	store_open(t, &ts)
	defer store_close(&ts)
	bs := &ts.blobs

	one := []u8{1, 2, 3, 4}
	two := []u8{1, 2, 3, 5}
	a, ok_a := blob_put(bs, .File, one)
	b, ok_b := blob_put(bs, .Avatar, one)
	c, ok_c := blob_put(bs, .File, two)
	testing.expect(t, ok_a && ok_b && ok_c)
	// The same content is stored as the same blob, with the kind it was first
	// stored with.
	testing.expect_value(t, b, a)
	testing.expect(t, c != a)
	first, _ := blob_get(bs, a)
	testing.expect_value(t, first.kind, Blob_Kind.File)
	testing.expect_value(t, pragma(t, &ts.db, "SELECT count(*) FROM blobs"), 2)

	// Even empty content can be stored.
	empty, ok_empty := blob_put(bs, .File, nil)
	testing.expect(t, ok_empty)
	content, read := blob_read(bs, empty, context.temp_allocator)
	testing.expect(t, read)
	testing.expect_value(t, len(content), 0)
}

@(test)
test_blob_delete :: proc(t: ^testing.T) {
	ts: Test_Store
	store_open(t, &ts)
	defer store_close(&ts)
	bs := &ts.blobs

	data := []u8{9, 9, 9}
	id, ok := blob_put(bs, .File, data)
	testing.expect(t, ok)
	b, _ := blob_get(bs, id)
	path := blob_path(bs, b.hash)
	testing.expect(t, os.exists(path))

	testing.expect(t, blob_delete(bs, id))
	testing.expect(t, !os.exists(path))
	_, found := blob_get(bs, id)
	testing.expect(t, !found)
	_, found = blob_find(bs, b.hash)
	testing.expect(t, !found)
	// Once deleted, there is nothing left to delete or read a second time.
	testing.expect(t, !blob_delete(bs, id))
	_, read := blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)

	// Storing the same data again creates a new blob, because an id is never
	// reused.
	again, ok_again := blob_put(bs, .File, data)
	testing.expect(t, ok_again)
	testing.expect(t, again > id)
}

@(test)
test_blob_file_damaged :: proc(t: ^testing.T) {
	ts: Test_Store
	store_open(t, &ts)
	defer store_close(&ts)
	bs := &ts.blobs

	id, ok := blob_put(bs, .File, []u8{1, 2, 3, 4, 5})
	testing.expect(t, ok)
	b, _ := blob_get(bs, id)
	path := blob_path(bs, b.hash)

	context.logger = log.nil_logger()
	// The file is truncated and then removed altogether. Either way it must not
	// be returned.
	testing.expect(t, os.write_entire_file(path, []u8{1, 2}) == nil)
	_, read := blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)
	testing.expect(t, os.remove(path) == nil)
	_, read = blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)
}

// Checks every statement the server prepares, as SQLite would run it. None may
// read through the tables that grow with the history, and the thread queries
// have to use messages_thread (a plan that walks messages by id from the anchor
// doesn't say SCAN, but is just as slow). The partial indexes are only used by
// queries that include the condition the indexes were created with (see Stmt),
// so a query that leaves it out silently stops using them.
@(test)
test_query_plans :: proc(t: ^testing.T) {
	db: DB
	testing.expect(t, db_open(&db, DB_MEMORY))
	defer db_close(&db)
	for id in Stmt {
		plan := db_plan(&db, id)
		for line in strings.split(plan, " | ", context.temp_allocator) {
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) < 2 || fields[0] != "SCAN" {
				continue
			}
			switch fields[1] {
			case "messages", "m", "reactions", "mentions":
				testing.expectf(t, false, "%v reads through a whole table: %s", id, plan)
			}
		}
		#partial switch id {
		case .Thread_Before,
		     .Thread_After,
		     .Thread_Any_Before,
		     .Thread_Any_After,
		     .Purge_Reply_Kept:
			testing.expectf(
				t,
				strings.contains(plan, "messages_thread"),
				"%v doesn't use messages_thread: %s",
				id,
				plan,
			)
		case .Thread_Recount:
			testing.expectf(
				t,
				strings.count(plan, "messages_thread") == 3,
				"%v doesn't use messages_thread in each count: %s",
				id,
				plan,
			)
		}
	}
}
