package server

import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "sqlite"

import "common:memtrack"
import "common:proto"

/*
Where the server's memory goes (common/memtrack, which main installs as
the allocator): a line in the log every memory_log (the config's
memory_log_minutes), to see a trend over a long run, and the whole
report for the owner, who asks for it from a client (Server_Memory).
Beside what memtrack sees there's what SQLite keeps for itself.
*/

Memory_Log :: struct {
	every:  time.Duration, // 0: never
	logged: time.Tick,
}

memory_log_open :: proc(s: ^Server, every: time.Duration) {
	s.memory_log = {
		every  = every,
		logged = time.tick_now(),
	}
}

// memory_sync logs the line, when it's time to.
memory_sync :: proc(s: ^Server) {
	m := &s.memory_log
	if m.every <= 0 || time.tick_since(m.logged) < m.every {
		return
	}
	m.logged = time.tick_now()
	log.info(memtrack.summary(memory_extras(s), context.temp_allocator))
}

// memory_request answers Server_Memory with the report, for the owner.
memory_request :: proc(s: ^Server, u: ^Conn, id: u32) {
	if .Owner not_in u.account.flags {
		respond(u, id, .Denied)
		return
	}
	report := memtrack.report(memory_extras(s), allocator = context.temp_allocator)
	// It's never near this big, but a line too many is cut, not sent.
	if len(report) > proto.MAX_BODY_SIZE {
		end := strings.last_index_byte(report[:proto.MAX_BODY_SIZE], '\n')
		report = report[:end + 1]
	}
	respond(u, id, .Ok, transmute([]u8)report)
}

// memory_extras is what SQLite takes, in the temp allocator.
@(private = "file")
memory_extras :: proc(s: ^Server) -> []memtrack.Extra {
	if s.db.conn == nil {
		return nil
	}
	used :: proc(db: ^sqlite.Connection, op: c.int) -> int {
		current, highwater: c.int
		if sqlite.db_status(db, op, &current, &highwater, 0) != sqlite.OK {
			return 0
		}
		return int(current)
	}
	cache := used(s.db.conn, sqlite.DBSTATUS_CACHE_USED)
	schema := used(s.db.conn, sqlite.DBSTATUS_SCHEMA_USED)
	stmts := used(s.db.conn, sqlite.DBSTATUS_STMT_USED)
	out := make([]memtrack.Extra, 1, context.temp_allocator)
	out[0] = {
		name   = "SQLite",
		bytes  = cache + schema + stmts,
		detail = fmt.tprintf(
			"cache %s, statements %s",
			memtrack.bytes_string(cache),
			memtrack.bytes_string(stmts),
		),
	}
	return out
}
