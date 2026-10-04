package server

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

_ :: time // only used when DB_EXERCISE

/*
The blob store: files the server keeps for good, such as the pictures
in messages. Each is a file in the data directory's blobs/ folder, named by the
SHA-256 of its content, with a row in the database's `blobs` table
saying what it is:

	blobs/ab/abcdef0123...   the first two digits are a folder, so no
	                         folder ends up with every file in it
	blobs/incoming/<id>      an attachment on its way in, emptied when
	                         the server starts

Being named by its content, the same picture posted twice is kept once,
and a file never changes once it's there: it can be copied for a backup
while the server runs.

A file is written under another name and renamed into place, so one
that's there is whole. Like the database's commits, writing one doesn't
wait for the disk.

What refers to a blob (a message, a profile) does so by its id. Nothing
here counts those references; finding the blobs nothing points at any
more is for whoever purges.
*/

BLOBS_DIR :: "blobs"
BLOB_HASH_SIZE :: 32

// Blob_Id is a blob's row in the database. 0 is never one.
Blob_Id :: proto.Blob_Id

// What a blob is, which decides how big it may be and who may fetch it.
Blob_Kind :: proto.Blob_Kind

Blob :: struct {
	id:            Blob_Id,
	hash:          [BLOB_HASH_SIZE]u8,
	size:          int, // bytes
	kind:          Blob_Kind,
	width, height: int, // pixels, for a picture
	created:       i64, // Unix milliseconds
}

Blob_Store :: struct {
	db:  ^DB,
	dir: string, // owned
}

// blob_store_open sets the store up over `db`, with its files in `dir`,
// which is created if it isn't there.
@(require_results)
blob_store_open :: proc(bs: ^Blob_Store, db: ^DB, dir: string) -> bool {
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.errorf("could not create %s: %v", dir, err)
		return false
	}
	bs.db = db
	bs.dir = strings.clone(dir)
	// What was on its way in when the server stopped isn't coming.
	incoming := blob_incoming_dir(bs)
	os.remove_all(incoming)
	if err := os.make_directory_all(incoming); err != nil && !os.is_directory(incoming) {
		log.errorf("could not create %s: %v", incoming, err)
		return false
	}
	return true
}

// blob_incoming_dir is where files being uploaded are written until
// they're whole (attachments.odin): beside the blobs, so that keeping
// one is a rename.
blob_incoming_dir :: proc(bs: ^Blob_Store, allocator := context.temp_allocator) -> string {
	path, _ := os.join_path({bs.dir, "incoming"}, allocator)
	return path
}

blob_store_close :: proc(bs: ^Blob_Store) {
	delete(bs.dir)
	bs^ = {}
}

blob_hash :: proc(data: []u8) -> (sum: [BLOB_HASH_SIZE]u8) {
	hash.hash_bytes_to_buffer(.SHA256, data, sum[:])
	return
}

// blob_path is where the blob with this hash is kept.
blob_path :: proc(
	bs: ^Blob_Store,
	sum: [BLOB_HASH_SIZE]u8,
	allocator := context.temp_allocator,
) -> string {
	sum := sum
	name := string(hex.encode(sum[:], context.temp_allocator))
	path, _ := os.join_path({bs.dir, name[:2], name}, allocator)
	return path
}

// blob_find is the blob with this content's hash, if the store has it.
blob_find :: proc(bs: ^Blob_Store, sum: [BLOB_HASH_SIZE]u8) -> (id: Blob_Id, found: bool) {
	sum := sum
	q := db_stmt(bs.db, .Blob_By_Hash)
	db_bind_blob(q, 1, sum[:])
	if row, ok := db_step(bs.db, q); ok && row {
		id = Blob_Id(db_col_int(q, 0))
		sqlite.reset(q)
		return id, true
	}
	return
}

/*
blob_put keeps `data` and returns its id. Content the store already has
isn't written again: the id is the one it got the first time, whatever
it was kept as then.
*/
@(require_results)
blob_put :: proc(
	bs: ^Blob_Store,
	kind: Blob_Kind,
	data: []u8,
	width := 0,
	height := 0,
	by: i64 = 0, // the account it came from, if any
) -> (
	id: Blob_Id,
	ok: bool,
) {
	sum := blob_hash(data)
	if existing, found := blob_find(bs, sum); found {
		return existing, true
	}

	path := blob_path(bs, sum)
	if !os.exists(path) {
		write_blob_file(bs, path, data) or_return
	}

	q := db_stmt(bs.db, .Blob_Add)
	db_bind_blob(q, 1, sum[:])
	db_bind_int(q, 2, i64(len(data)))
	db_bind_int(q, 3, i64(kind))
	db_bind_int(q, 4, i64(width))
	db_bind_int(q, 5, i64(height))
	db_bind_int(q, 6, unix_ms())
	if by != 0 {
		db_bind_int(q, 7, by)
	} else {
		db_bind_null(q, 7)
	}
	db_run(bs.db, q) or_return
	return Blob_Id(db_last_id(bs.db)), true
}

/*
blob_adopt keeps the file at `part`, whose content hashes to `sum`, as a
blob: renamed into the store, or, if the store has that content already,
deleted, and the id is the one it has. Either way the blob counts as new
for an hour, so a collect doesn't take it before it's used.
*/
@(require_results)
blob_adopt :: proc(
	bs: ^Blob_Store,
	kind: Blob_Kind,
	part: string,
	sum: [BLOB_HASH_SIZE]u8,
	size: int,
	by: i64,
) -> (
	id: Blob_Id,
	ok: bool,
) {
	sum := sum
	if existing, found := blob_find(bs, sum); found {
		os.remove(part)
		q := db_stmt(bs.db, .Blob_Touch)
		db_bind_int(q, 1, i64(existing))
		db_bind_int(q, 2, unix_ms())
		db_run(bs.db, q) or_return
		return existing, true
	}
	path := blob_path(bs, sum)
	dir := os.dir(path)
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.errorf("could not create %s: %v", dir, err)
		return
	}
	if err := os.rename(part, path); err != nil {
		log.errorf("could not rename %s to %s: %v", part, path, err)
		return
	}
	q := db_stmt(bs.db, .Blob_Add)
	db_bind_blob(q, 1, sum[:])
	db_bind_int(q, 2, i64(size))
	db_bind_int(q, 3, i64(kind))
	db_bind_int(q, 4, 0)
	db_bind_int(q, 5, 0)
	db_bind_int(q, 6, unix_ms())
	db_bind_int(q, 7, by)
	db_run(bs.db, q) or_return
	return Blob_Id(db_last_id(bs.db)), true
}

// write_blob_file writes a blob's file: under a name of its own first,
// then renamed, so that a file with a blob's name is always a whole one.
@(private = "file")
write_blob_file :: proc(bs: ^Blob_Store, path: string, data: []u8) -> bool {
	dir := os.dir(path)
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.errorf("could not create %s: %v", dir, err)
		return false
	}
	random: [8]u8
	crypto.rand_bytes(random[:])
	incoming := strings.concatenate(
		{path, ".", string(hex.encode(random[:], context.temp_allocator))},
		context.temp_allocator,
	)
	if err := os.write_entire_file(incoming, data, {.Read_User, .Write_User}); err != nil {
		log.errorf("could not write %s: %v", incoming, err)
		os.remove(incoming)
		return false
	}
	if err := os.rename(incoming, path); err != nil {
		log.errorf("could not rename %s to %s: %v", incoming, path, err)
		os.remove(incoming)
		return false
	}
	return true
}

/*
Testing aid: built with -define:YAP_DB_EXERCISE=true, the server writes
to its database and blob store all the time, which nothing else does
yet: ten times a second a new blob of 64 KB and a note in `meta`, and
every so often the oldest blobs are deleted again. Run with people
talking, the log then says what that costs the loop (see SLOW_ITERATION
in server.odin).
*/
DB_EXERCISE :: #config(YAP_DB_EXERCISE, false)

when DB_EXERCISE {
	@(private = "file")
	exercise_last: time.Tick
	@(private = "file")
	exercise_ids: [dynamic]Blob_Id

	db_exercise :: proc(s: ^Server) {
		if time.tick_since(exercise_last) < 100 * time.Millisecond {
			return
		}
		exercise_last = time.tick_now()
		data := make([]u8, 64 * 1024, context.temp_allocator)
		crypto.rand_bytes(data)
		if id, ok := blob_put(&s.blobs, .Image, data, 100, 100); ok {
			append(&exercise_ids, id)
		}
		db_meta_set(&s.db, "exercise", i64(len(exercise_ids)))
		if len(exercise_ids) >= 100 {
			for id in exercise_ids[:50] {
				blob_delete(&s.blobs, id)
			}
			remove_range(&exercise_ids, 0, 50)
			log.infof("exercise: 50 blobs deleted, %d log pages", s.db.log_pages)
		}
	}
} else {
	db_exercise :: proc(s: ^Server) {}
}

// blob_get is what the store knows about a blob.
blob_get :: proc(bs: ^Blob_Store, id: Blob_Id) -> (b: Blob, found: bool) {
	q := db_stmt(bs.db, .Blob_By_Id)
	db_bind_int(q, 1, i64(id))
	row, ok := db_step(bs.db, q)
	if !ok || !row {
		return
	}
	defer sqlite.reset(q)
	if !db_col_into(q, 0, b.hash[:]) {
		log.errorf("blob %d has a hash of the wrong size", id)
		return {}, false
	}
	b.id = id
	b.size = int(db_col_int(q, 1))
	b.kind = Blob_Kind(db_col_int(q, 2))
	b.width = int(db_col_int(q, 3))
	b.height = int(db_col_int(q, 4))
	b.created = db_col_int(q, 5)
	return b, true
}

// blob_read is a blob's content, allocated with `allocator`. A file
// that's missing or not the size the database says is an error, and
// logged.
@(require_results)
blob_read :: proc(
	bs: ^Blob_Store,
	id: Blob_Id,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	b := blob_get(bs, id) or_return
	path := blob_path(bs, b.hash)
	content, err := os.read_entire_file(path, allocator)
	if err != nil {
		log.errorf("blob %d: could not read %s: %v", id, path, err)
		return nil, false
	}
	if len(content) != b.size {
		log.errorf("blob %d: %s is %d bytes, not %d", id, path, len(content), b.size)
		delete(content, allocator)
		return nil, false
	}
	return content, true
}

// blob_delete forgets a blob and removes its file. It's for the caller
// to know that nothing refers to it any more.
blob_delete :: proc(bs: ^Blob_Store, id: Blob_Id) -> bool {
	b := blob_get(bs, id) or_return
	q := db_stmt(bs.db, .Blob_Delete)
	db_bind_int(q, 1, i64(id))
	db_run(bs.db, q) or_return
	// The row first, for good, and then the file: were the server to
	// stop in between, a file without a row is only wasted room, where a
	// row without its file would be a blob that can't be read.
	db_commit(bs.db)
	path := blob_path(bs, b.hash)
	if err := os.remove(path); err != nil && os.exists(path) {
		// The row is gone, so nothing points at the file; it only takes
		// up room.
		log.warnf("could not remove %s: %v", path, err)
	}
	return true
}
