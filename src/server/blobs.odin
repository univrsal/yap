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

// The blob store: files the server keeps permanently, such as the files
// attached to messages. Each blob is a file in the blobs/ folder of the
// data directory. It is named after the SHA-256 hash of its content and
// has a row in the database's `blobs` table that describes it:
//
//	blobs/ab/abcdef0123...   the first two hex digits are a folder, so no
//	                         single folder ends up holding every file
//	blobs/incoming/<id>      an attachment that is still being uploaded,
//	                         emptied when the server starts
//
// Because a blob is named after its content, the same picture posted
// twice is only stored once. A blob file never changes after it is
// written, so it can be copied for a backup while the server is running.
//
// A file is first written under a temporary name and then renamed into
// place, so a file under a blob's name is always complete. Like the
// database's commits, writing a file doesn't wait for the disk.
//
// Things that use a blob (a message, a profile) refer to it by its id.
// The store doesn't count these references. Finding blobs that nothing
// refers to any more is left to the code that purges unused blobs.

BLOBS_DIR :: "blobs"
BLOB_HASH_SIZE :: 32

// Blob_Id is a blob's row in the database. 0 is never one.
Blob_Id :: proto.Blob_Id

// Blob_Kind is what a blob is used for. It decides how big the blob may be
// and who may fetch it.
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

// blob_store_open sets up the store on `db` with its files in `dir`,
// which is created if it doesn't exist.
@(require_results)
blob_store_open :: proc(bs: ^Blob_Store, db: ^DB, dir: string) -> bool {
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		log.errorf("could not create %s: %v", dir, err)
		return false
	}
	bs.db = db
	bs.dir = strings.clone(dir)
	// Uploads that were in progress when the server stopped can't be resumed.
	incoming := blob_incoming_dir(bs)
	remove_tree(incoming)
	if err := os.make_directory_all(incoming); err != nil && !os.is_directory(incoming) {
		log.errorf("could not create %s: %v", incoming, err)
		return false
	}
	return true
}

// blob_incoming_dir is where uploaded files are written until they are
// complete (attachments.odin). It is next to the blobs so that storing a
// finished upload is just a rename.
blob_incoming_dir :: proc(bs: ^Blob_Store, allocator := context.temp_allocator) -> string {
	path, _ := os.join_path({bs.dir, "incoming"}, allocator)
	return path
}

// remove_tree removes `path` and, if it's a folder, everything in it. It
// is os.remove_all done by hand. On Windows os.remove_all uses
// SHFileOperationW, which loads the shell and raises exceptions of its
// own (for example RPC_S_SERVER_UNAVAILABLE when a service it needs is
// off). Those exceptions are handled, but the test runner's exception
// handler treats any of them as a crash and stops the test, and then
// waits for it forever.
remove_tree :: proc(path: string) {
	if os.remove(path) == nil {
		return
	}
	// The path is either not empty or doesn't exist. A link to a folder
	// was already removed above, so this only lists real folders.
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.type == .Directory {
			remove_tree(e.fullpath)
		} else {
			os.remove(e.fullpath)
		}
	}
	os.remove(path)
}

blob_store_close :: proc(bs: ^Blob_Store) {
	delete(bs.dir)
	bs^ = {}
}

blob_hash :: proc(data: []u8) -> (sum: [BLOB_HASH_SIZE]u8) {
	hash.hash_bytes_to_buffer(.SHA256, data, sum[:])
	return
}

// blob_path returns where the blob with this hash is stored.
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

// blob_find returns the blob with this content hash, if the store has it.
blob_find :: proc(bs: ^Blob_Store, sum: [BLOB_HASH_SIZE]u8) -> (id: Blob_Id, found: bool) {
	sum := sum
	q := db_query(bs.db, .Blob_By_Hash, sum[:])
	if row, ok := db_step(bs.db, q); ok && row {
		id = Blob_Id(db_col_int(q, 0))
		sqlite.reset(q)
		return id, true
	}
	return
}

// blob_put stores `data` and returns its id. Content that the store
// already has isn't written again. Instead the id from the first time is
// returned, regardless of the kind it was stored as then.
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

	q := db_query(
		bs.db,
		.Blob_Add,
		sum[:],
		i64(len(data)),
		i64(kind),
		i64(width),
		i64(height),
		unix_ms(),
	)
	if by != 0 {
		db_bind_int(q, 7, by)
	} else {
		db_bind_null(q, 7)
	}
	db_run(bs.db, q) or_return
	return Blob_Id(db_last_id(bs.db)), true
}

// blob_adopt stores the file at `part`, whose content hashes to `sum`, as
// a blob. The file is renamed into the store or, if the store already has
// that content, deleted and the existing blob's id is returned. Either
// way the blob counts as new for an hour, so the garbage collection
// doesn't remove it before it is used. `width` and `height` are a
// picture's size, for a new blob.
@(require_results)
blob_adopt :: proc(
	bs: ^Blob_Store,
	kind: Blob_Kind,
	part: string,
	sum: [BLOB_HASH_SIZE]u8,
	size: int,
	by: i64,
	width := 0,
	height := 0,
) -> (
	id: Blob_Id,
	ok: bool,
) {
	sum := sum
	if existing, found := blob_find(bs, sum); found {
		os.remove(part)
		db_write(bs.db, .Blob_Touch, i64(existing), unix_ms()) or_return
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
	db_write(
		bs.db,
		.Blob_Add,
		sum[:],
		i64(size),
		i64(kind),
		i64(width),
		i64(height),
		unix_ms(),
		by,
	) or_return
	return Blob_Id(db_last_id(bs.db)), true
}

// write_blob_file writes a blob's file. It is first written under a
// temporary name and then renamed, so a file with a blob's name is always
// complete.
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

// Testing aid: when built with -define:YAP_DB_EXERCISE=true, the server
// continuously writes to its database and blob store, which nothing else
// does yet. Ten times a second it stores a new 64 KB blob and a note in
// `meta`, and every so often the oldest blobs are deleted again. When
// run while people are chatting, the log shows what this costs the loop
// (see SLOW_TURN in loop_stats.odin).
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
		if id, ok := blob_put(&s.blobs, .Avatar, data, 100, 100); ok {
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

// blob_get returns the store's information about a blob.
blob_get :: proc(bs: ^Blob_Store, id: Blob_Id) -> (b: Blob, found: bool) {
	q := db_query(bs.db, .Blob_By_Id, i64(id))
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

// blob_read returns a blob's content, allocated with `allocator`. A file
// that is missing or doesn't have the size recorded in the database is
// an error and is logged.
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

// blob_delete removes a blob's database row and its file. The caller
// must make sure that nothing refers to the blob any more.
blob_delete :: proc(bs: ^Blob_Store, id: Blob_Id) -> bool {
	b := blob_get(bs, id) or_return
	db_write(bs.db, .Blob_Delete, i64(id)) or_return
	// Commit the row deletion first and remove the file afterwards. If the
	// server stops in between, a file without a row only wastes space,
	// whereas a row without its file would be a blob that can't be read.
	db_commit(bs.db)
	path := blob_path(bs, b.hash)
	if err := os.remove(path); err != nil && os.exists(path) {
		// The row is gone, so nothing points at the file. It only wastes
		// space.
		log.warnf("could not remove %s: %v", path, err)
	}
	return true
}
