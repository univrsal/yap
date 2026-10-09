package server

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

/*
Tests of the database and the blob store. Most run on a database in
memory; the ones about what's on disk get a folder of their own under
the system's temporary one.

The test runner counts an error in the log as a failure, so where a test
makes something fail on purpose, it does so with the log switched off.
*/

// A folder for one test, removed when the test is over.
@(private = "file")
test_dir :: proc(t: ^testing.T) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	testing.expect(t, err == nil)
	return dir
}

@(private = "file")
file_in :: proc(dir, name: string) -> string {
	path, _ := os.join_path({dir, name}, context.temp_allocator)
	return path
}

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

	// A turn's writes are one transaction, open until it's committed.
	testing.expect(t, !db.in_tx)
	testing.expect(t, db_meta_set(&db, "a", 1))
	testing.expect(t, db.in_tx)
	testing.expect(t, db_meta_set(&db, "b", 2))
	db_commit(&db)
	testing.expect(t, !db.in_tx)
	// Committing with nothing open is nothing.
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
		// Laid out so that purging can give room back, and logging ahead.
		testing.expect_value(t, pragma(t, &db, "PRAGMA auto_vacuum"), 2)
		testing.expect_value(t, pragma(t, &db, "PRAGMA synchronous"), 1)
		testing.expect_value(t, pragma(t, &db, "PRAGMA wal_autocheckpoint"), 0)
		created, _ = db_meta(&db, "created")
		testing.expect(t, db_meta_set(&db, "kept", 7))
		db_commit(&db)
		testing.expect(t, db.log_pages > 0)

		// Somebody else wanting the same file is told it's taken.
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

	// Opened again, it's the same database: nothing is made a second time.
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
	// What was committed survives the server going without closing the
	// database; what wasn't doesn't.
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		testing.expect(t, db_meta_set(&db, "committed", 1))
		db_commit(&db)
		testing.expect(t, db_meta_set(&db, "open", 1))
		// As close to being killed as a test gets: the connection is
		// closed without a commit.
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

	// The file is where its hash says, and nothing else is left lying
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
	// The same content is the same blob, kept as it first came.
	testing.expect_value(t, b, a)
	testing.expect(t, c != a)
	first, _ := blob_get(bs, a)
	testing.expect_value(t, first.kind, Blob_Kind.File)
	testing.expect_value(t, pragma(t, &ts.db, "SELECT count(*) FROM blobs"), 2)

	// Even nothing at all can be kept.
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
	// Gone is gone: there's nothing to delete or read a second time.
	testing.expect(t, !blob_delete(bs, id))
	_, read := blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)

	// Put again it's a new blob: an id is never given out twice.
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
	// Cut short, and then gone altogether: either way it isn't handed out.
	testing.expect(t, os.write_entire_file(path, []u8{1, 2}) == nil)
	_, read := blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)
	testing.expect(t, os.remove(path) == nil)
	_, read = blob_read(bs, id, context.temp_allocator)
	testing.expect(t, !read)
}

/*
Every statement the server prepares, as SQLite would run it: none may
read through the tables that grow with the history, and the thread
queries have to go by messages_thread (a plan that walks messages by id
from the anchor doesn't say SCAN, but is as slow). With the partial
indexes, a query that leaves out the condition they're made with (see
Stmt) quietly loses them.
*/
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
