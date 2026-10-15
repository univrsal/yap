// Bindings for SQLite (https://sqlite.org, public domain), which is used
// for the server's database. Only the few procedures the server calls are
// bound, exactly as they are declared in sqlite3.h. Build the library with
// build.sh / build.bat at the repo root (see yap_sqlite.c for how it is
// configured).
//
// Everything here is SQLite's C interface unchanged. The more convenient
// wrappers are in src/server/db.odin.
package sqlite

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_sqlite.lib"
} else {
	@(private)
	LIB :: "libyap_sqlite.a"
}

when !#exists(LIB) {
	#panic(
		"src/server/sqlite/" +
		LIB +
		" is missing; build it with build.sh (or build.bat on Windows)",
	)
}

when ODIN_OS == .Windows {
	foreign import lib {LIB}
} else {
	// SQLite's mutexes are pthreads mutexes, and it needs a little of libm.
	foreign import lib {LIB, "system:m", "system:pthread"}
}

Connection :: struct {}
Stmt :: struct {}

// Result codes. Any other code is an error (errmsg says which).
OK :: 0
BUSY :: 5 // another process holds the database
INTERRUPT :: 9 // the progress handler stopped the statement
ROW :: 100 // step produced a row
DONE :: 101 // step has finished

// open_v2 flags.
OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004

// wal_checkpoint_v2 modes.
CHECKPOINT_PASSIVE :: 0
CHECKPOINT_TRUNCATE :: 3

// The value type that column_type returns for a null value.
NULL :: 5

// Destructor argument for bind_text and bind_blob that makes SQLite copy
// the data before the call returns (SQLITE_TRANSIENT).
TRANSIENT :: rawptr(~uintptr(0))

Wal_Hook :: #type proc "c" (arg: rawptr, db: ^Connection, name: cstring, pages: c.int) -> c.int
// Called every so many steps of a statement. Returning non-zero stops it.
Progress_Handler :: #type proc "c" (arg: rawptr) -> c.int

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign lib {
	libversion :: proc() -> cstring ---
	open_v2 :: proc(filename: cstring, db: ^^Connection, flags: c.int, vfs: cstring) -> c.int ---
	close :: proc(db: ^Connection) -> c.int ---
	errmsg :: proc(db: ^Connection) -> cstring ---
	exec :: proc(db: ^Connection, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	last_insert_rowid :: proc(db: ^Connection) -> i64 ---
	changes :: proc(db: ^Connection) -> c.int ---
	wal_hook :: proc(db: ^Connection, hook: Wal_Hook, arg: rawptr) -> rawptr ---
	progress_handler :: proc(db: ^Connection, steps: c.int, handler: Progress_Handler, arg: rawptr) ---
	wal_checkpoint_v2 :: proc(db: ^Connection, name: cstring, mode: c.int, log_frames: ^c.int, checkpointed: ^c.int) -> c.int ---

	prepare_v2 :: proc(db: ^Connection, sql: [^]u8, bytes: c.int, stmt: ^^Stmt, tail: ^[^]u8) -> c.int ---
	finalize :: proc(stmt: ^Stmt) -> c.int ---
	reset :: proc(stmt: ^Stmt) -> c.int ---
	clear_bindings :: proc(stmt: ^Stmt) -> c.int ---
	step :: proc(stmt: ^Stmt) -> c.int ---
	// Returns non-zero while a statement has been stepped but not yet reset
	// or run to its end. Such a statement holds a read open, which keeps
	// checkpoints from finishing.
	stmt_busy :: proc(stmt: ^Stmt) -> c.int ---

	// Parameters are numbered from 1.
	bind_int64 :: proc(stmt: ^Stmt, index: c.int, value: i64) -> c.int ---
	bind_text :: proc(stmt: ^Stmt, index: c.int, text: [^]u8, bytes: c.int, destructor: rawptr) -> c.int ---
	bind_blob :: proc(stmt: ^Stmt, index: c.int, data: rawptr, bytes: c.int, destructor: rawptr) -> c.int ---
	bind_null :: proc(stmt: ^Stmt, index: c.int) -> c.int ---

	// Columns are numbered from 0. The memory that text and blob results
	// point at belongs to SQLite and is only valid until the statement is
	// stepped or reset again.
	column_type :: proc(stmt: ^Stmt, column: c.int) -> c.int ---
	column_int64 :: proc(stmt: ^Stmt, column: c.int) -> i64 ---
	column_text :: proc(stmt: ^Stmt, column: c.int) -> [^]u8 ---
	column_blob :: proc(stmt: ^Stmt, column: c.int) -> rawptr ---
	column_bytes :: proc(stmt: ^Stmt, column: c.int) -> c.int ---

	// Reports how much a connection uses (DBSTATUS_*). This works without
	// MEMSTATUS.
	db_status :: proc(db: ^Connection, op: c.int, current: ^c.int, highwater: ^c.int, reset: c.int) -> c.int ---
}

// db_status ops for the memory used by the page cache, the schema and
// prepared statements.
DBSTATUS_CACHE_USED :: 1
DBSTATUS_SCHEMA_USED :: 2
DBSTATUS_STMT_USED :: 3
