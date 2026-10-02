/*
SQLite (https://sqlite.org, public domain), for the server's database:
the few procedures the server calls, as they are in sqlite3.h. Build the
library with build.sh / build.bat at the repo root (see yap_sqlite.c for
how it's configured).

Everything here is SQLite's C interface unchanged; what makes it
comfortable to use is in src/server/db.odin.
*/
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
	#panic("src/server/sqlite/" + LIB + " is missing; build it with build.sh (or build.bat on Windows)")
}

when ODIN_OS == .Windows {
	foreign import lib {LIB}
} else {
	// Its mutexes are pthreads', and a little of libm.
	foreign import lib {LIB, "system:m", "system:pthread"}
}

Connection :: struct {}
Stmt :: struct {}

// Result codes; anything else is an error (errmsg says which).
OK :: 0
BUSY :: 5 // another process has the database
INTERRUPT :: 9 // the progress handler stopped it
ROW :: 100 // step has a row
DONE :: 101 // step has finished

// open_v2 flags.
OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004

// wal_checkpoint_v2 modes.
CHECKPOINT_PASSIVE :: 0
CHECKPOINT_TRUNCATE :: 3

// What column_type says a value is.
NULL :: 5

// For bind_text and bind_blob: SQLite copies what it's given before the
// call returns (SQLITE_TRANSIENT).
TRANSIENT :: rawptr(~uintptr(0))

Wal_Hook :: #type proc "c" (arg: rawptr, db: ^Connection, name: cstring, pages: c.int) -> c.int
// Called every so many steps of a statement; non-zero stops it.
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

	// Parameters are numbered from 1.
	bind_int64 :: proc(stmt: ^Stmt, index: c.int, value: i64) -> c.int ---
	bind_text :: proc(stmt: ^Stmt, index: c.int, text: [^]u8, bytes: c.int, destructor: rawptr) -> c.int ---
	bind_blob :: proc(stmt: ^Stmt, index: c.int, data: rawptr, bytes: c.int, destructor: rawptr) -> c.int ---
	bind_null :: proc(stmt: ^Stmt, index: c.int) -> c.int ---

	// Columns are numbered from 0. What text and blob point at is
	// SQLite's, and good until the statement is stepped or reset.
	column_type :: proc(stmt: ^Stmt, column: c.int) -> c.int ---
	column_int64 :: proc(stmt: ^Stmt, column: c.int) -> i64 ---
	column_text :: proc(stmt: ^Stmt, column: c.int) -> [^]u8 ---
	column_blob :: proc(stmt: ^Stmt, column: c.int) -> rawptr ---
	column_bytes :: proc(stmt: ^Stmt, column: c.int) -> c.int ---
}
