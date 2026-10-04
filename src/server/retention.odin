package server

import "core:log"
import "core:os"
import "core:time"

import "common:proto"
import "sqlite"

/*
Retention: removing what's old for good (src/common/proto/purge.odin).

What the config says to keep no longer goes on its own, at startup and
once an hour after: messages older than `message_days`, the pictures of
those older than `image_days`, their files (attachments.odin) older than
`file_days`, and the oldest pictures and files while they take more than
`blob_megabytes`. Somebody with Permission.Purge can purge a
conversation, or all of them, up to a time (Purge), and so can whoever
runs the server, from the command line with it stopped (cli.odin). Each
run, and each purge, then removes the stored files nothing uses any
more and hands the room they took in the database back to the
filesystem.

	purge messages   the messages, with their reactions, mentions and
	                 pins; not pinned ones, nor a thread's root while
	                 any of its replies is kept
	purge pictures   the messages stay, with blob NULL: an Image
	                 without a picture; not pinned ones
	purge files      the same for the files messages carry: each stays
	                 in the message's list, with blob NULL
	purge stored     pictures and files both, the oldest messages' first,
	                 until enough room is free (blob_megabytes)
	collect          the blobs nothing points at (no message, no
	                 account's picture, not the emoji sheet) that are
	                 older than an hour, so one that's just been uploaded
	                 for a message that isn't posted yet stays; the row
	                 first, for good, and then the file
	vacuum           the database's free pages, a few at a time

All of this is done by the server's loop, which also relays voice, so
it's done a little at a time: a few dozen rows, then another few dozen,
for at most RETENTION_BUDGET a turn and with turns of other things in
between. Nothing waits for it.

Purges go by message ids, not times: a time is turned into the id of the
first message posted at or after it (msg_boundary), ids going up with
time. What a purge removes is then "below that id", which is what
clients are told (Msgs_Purged) to drop.

A purge somebody asked for is written down in the database's meta as it
goes, so a server that's stopped in the middle carries on with it when
it starts again. The hourly run needs no such note: it starts over.
*/

Retention_Config :: struct {
	message_days:   int,
	image_days:     int,
	file_days:      int,
	blob_megabytes: int,
}

// How often what the config says is applied, and how long a turn of the
// loop spends on it at most, with at least RETENTION_PAUSE between such
// turns so that other things get done.
RETENTION_INTERVAL :: time.Hour
RETENTION_BUDGET :: 2 * time.Millisecond
RETENTION_PAUSE :: 2 * time.Millisecond
// Rows looked at in one go.
PURGE_CHUNK :: 64
// A blob nothing uses is kept this long after it was stored.
BLOB_GRACE_MS :: 60 * 60 * 1000
// Free pages handed back in one go.
VACUUM_PAGES :: "32"
// What purging writes goes through the database's log like anything
// else. Left to itself the log is moved into the database when it's
// grown to DB_LOG_MOST, all at once, which takes tens of milliseconds.
// Instead, retention's turn ends once the log is this long (pages, of 4
// KB), and the next is spent moving it, which takes a few: about a
// millisecond and 10 microseconds a page.
RETENTION_LOG_PAGES :: 128
// How long the server's socket waits for a packet while retention has
// work: the loop comes round that often even with nobody there, rather
// than ten times a second.
RETENTION_WAIT :: 2 * time.Millisecond

DAY_MS :: 24 * 60 * 60 * 1000

// Where the database keeps the purge somebody asked for, while it goes
// on, and the emoji sheet that's in use (emoji.odin).
@(private = "file")
PURGE_META_WHAT :: "purge_what"
@(private = "file")
PURGE_META_CONV :: "purge_conv"
@(private = "file")
PURGE_META_BELOW :: "purge_below"
@(private = "file")
PURGE_META_CURSOR :: "purge_cursor"
EMOJI_SHEET_META :: "emoji_sheet"

Purge_Step_Kind :: enum u8 {
	Messages,
	Pictures,
	Files,
	Stored, // pictures and files, until `bytes` of them have gone
	Size_Cap, // becomes Stored if they take too much room
	Collect,
	Vacuum,
}

Purge_Step :: struct {
	kind:   Purge_Step_Kind,
	conv:   proto.Conv_Id, // Messages, Pictures, Files: 0 for every one
	below:  proto.Msg_Id, // Messages, Pictures, Files, Stored: what's below this id
	cursor: i64, // the last message or blob looked at
	// Stored: stop once this many bytes have gone (0: go on to `below`).
	bytes:  i64,
	// Somebody asked for it: it's written down until it's done, and
	// what it did is the answer.
	asked:  bool,
	// Collect: the emoji sheet, which stays.
	keep:   Blob_Id,
	// What it did: messages removed or stripped, or blobs removed; and
	// the conversations that changed, and roots kept whose threads may
	// have lost replies.
	count:  int,
	freed:  i64,
	convs:  map[proto.Conv_Id]bool,
	roots:  [dynamic]proto.Msg_Id,
}

Retention :: struct {
	config:    Retention_Config,
	// What's to be done, the first under way.
	steps:     [dynamic]Purge_Step,
	// When the config was last applied; never yet if `ran` isn't set.
	// And it's due again, as soon as what's queued is done.
	last_run:  time.Tick,
	ran:       bool,
	due:       bool,
	last_turn: time.Tick,
	// A purge somebody asked for is under way, and who, to answer when
	// it's done (if they're still there), with what it did so far.
	asked:     bool,
	asker:     Purge_Asker,
	messages:  int,
	blobs:     int,
}

Purge_Asker :: struct {
	waiting:  bool,
	key:      [proto.KEY_SIZE]u8,
	instance: u64,
	request:  u32,
}

/*
retention_open sets retention up with the config's limits, and picks up
a purge that was asked for and hasn't finished.
*/
retention_open :: proc(r: ^Retention, db: ^DB, config: Retention_Config) {
	r.config = config
	below, found := db_meta(db, PURGE_META_BELOW)
	if !found || below == 0 {
		return
	}
	what, _ := db_meta(db, PURGE_META_WHAT)
	conv, _ := db_meta(db, PURGE_META_CONV)
	cursor, _ := db_meta(db, PURGE_META_CURSOR)
	kind := step_kind(proto.Purge_What(what))
	append(&r.steps, Purge_Step{kind = kind, conv = proto.Conv_Id(conv), below = proto.Msg_Id(below), cursor = cursor, asked = true})
	append(&r.steps, Purge_Step{kind = .Collect, asked = true}, Purge_Step{kind = .Vacuum})
	r.asked = true
	log.infof("carrying on with the purge of %s below message %d", conv_label(proto.Conv_Id(conv)), below)
}

// step_kind is the step that purges `what`.
@(private = "file")
step_kind :: proc(what: proto.Purge_What) -> Purge_Step_Kind {
	switch what {
	case .Images:
		return .Pictures
	case .Files:
		return .Files
	case .Messages:
	}
	return .Messages
}

retention_close :: proc(r: ^Retention) {
	for &step in r.steps {
		step_destroy(&step)
	}
	delete(r.steps)
	r^ = {}
}

step_destroy :: proc(step: ^Purge_Step) {
	delete(step.convs)
	delete(step.roots)
	step^ = {}
}

@(private = "file")
conv_label :: proc(conv: proto.Conv_Id) -> string {
	return "every conversation" if conv == 0 else "a conversation"
}

/*
msg_boundary is the id of the first message posted at or after `time`
(Unix milliseconds), or one past the last if there's none: what was
posted before `time` is what's below it. Found by halving, a message
at a time, which counts on ids going up with time; a clock that went
back now and then makes it off by about as much.
*/
msg_boundary :: proc(db: ^DB, time_ms: i64) -> proto.Msg_Id {
	q := db_stmt(db, .Msg_Bounds)
	lo, hi: i64
	if row, ok := db_step(db, q); ok && row {
		lo, hi = db_col_int(q, 0), db_col_int(q, 1) + 1
		sqlite.reset(q)
	}
	if hi <= 1 {
		return 1
	}
	// The first place whose next message isn't older than `time`.
	for lo < hi {
		mid := lo + (hi - lo) / 2
		q = db_stmt(db, .Msg_From)
		db_bind_int(q, 1, mid)
		row, ok := db_step(db, q)
		if !ok {
			return proto.Msg_Id(lo)
		}
		if !row {
			hi = mid
			continue
		}
		id, at := db_col_int(q, 0), db_col_int(q, 1)
		sqlite.reset(q)
		if at >= time_ms {
			hi = mid
		} else {
			lo = id + 1
		}
	}
	return proto.Msg_Id(lo)
}

/*
retention_schedule queues what the config says, as of `now_ms`: the
messages, then the pictures, the stored files that are left over, the
pictures past the size limit and the files they leave, and the
database's free pages. Collecting and vacuuming are done even with no
limits set: they only take away what nothing uses.
*/
retention_schedule :: proc(r: ^Retention, db: ^DB, now_ms: i64) {
	c := r.config
	if c.message_days > 0 {
		below := msg_boundary(db, now_ms - i64(c.message_days) * DAY_MS)
		append(&r.steps, Purge_Step{kind = .Messages, below = below})
	}
	if c.image_days > 0 && (c.message_days == 0 || c.image_days < c.message_days) {
		below := msg_boundary(db, now_ms - i64(c.image_days) * DAY_MS)
		append(&r.steps, Purge_Step{kind = .Pictures, below = below})
	}
	if c.file_days > 0 && (c.message_days == 0 || c.file_days < c.message_days) {
		below := msg_boundary(db, now_ms - i64(c.file_days) * DAY_MS)
		append(&r.steps, Purge_Step{kind = .Files, below = below})
	}
	append(&r.steps, Purge_Step{kind = .Collect})
	if c.blob_megabytes > 0 {
		append(&r.steps, Purge_Step{kind = .Size_Cap}, Purge_Step{kind = .Collect})
	}
	append(&r.steps, Purge_Step{kind = .Vacuum})
}

/*
retention_ask queues a purge somebody asked for, ahead of what the
config wants done, and writes it down; false if one is under way
already.
*/
retention_ask :: proc(r: ^Retention, db: ^DB, p: proto.Purge, now_ms: i64) -> bool {
	if r.asked {
		return false
	}
	before := min(i64(p.before), now_ms)
	step := Purge_Step {
		kind  = step_kind(p.what),
		conv  = p.conv,
		below = msg_boundary(db, before),
		asked = true,
	}
	db_meta_set(db, PURGE_META_WHAT, i64(p.what))
	db_meta_set(db, PURGE_META_CONV, i64(p.conv))
	db_meta_set(db, PURGE_META_CURSOR, 0)
	db_meta_set(db, PURGE_META_BELOW, i64(step.below))
	// After the step that's under way, which may be halfway.
	at := min(1, len(r.steps))
	inject_at(&r.steps, at, step, Purge_Step{kind = .Collect, asked = true}, Purge_Step{kind = .Vacuum})
	r.asked = true
	r.messages, r.blobs = 0, 0
	return true
}

/*
retention_chunk does a little of the first step. When that finishes the
step it's taken off the queue and returned, `finished`, for the caller
to tell whoever needs telling and destroy.
*/
retention_chunk :: proc(r: ^Retention, bs: ^Blob_Store, now_ms: i64) -> (done: Purge_Step, finished: bool) {
	if len(r.steps) == 0 {
		return
	}
	step := &r.steps[0]
	db := bs.db
	over: bool
	switch step.kind {
	case .Messages:
		over = purge_messages_chunk(db, step)
	case .Pictures:
		over = purge_pictures_chunk(db, step)
	case .Files:
		over = purge_files_chunk(db, step)
	case .Stored:
		over = purge_stored_chunk(db, step)
	case .Size_Cap:
		total: i64
		q := db_stmt(db, .Stored_Bytes)
		if row, ok := db_step(db, q); ok && row {
			total = db_col_int(q, 0)
			sqlite.reset(q)
		}
		limit := i64(r.config.blob_megabytes) * 1024 * 1024
		if total <= limit {
			over = true
			break
		}
		log.infof("pictures and files take %d MB, more than %d: the oldest go", total / (1024 * 1024), r.config.blob_megabytes)
		_, last := msg_bounds(db)
		step^ = {kind = .Stored, below = last + 1, bytes = total - limit}
	case .Collect:
		if step.cursor == 0 {
			keep, _ := db_meta(db, EMOJI_SHEET_META)
			step.keep = Blob_Id(keep)
		}
		over = collect_chunk(bs, step, now_ms)
	case .Vacuum:
		db_begin(db)
		if !db_exec(db, "PRAGMA incremental_vacuum(" + VACUUM_PAGES + ")") {
			over = true
			break
		}
		free, _ := db_pragma_int(db, "PRAGMA freelist_count")
		over = free == 0
	}
	if step.asked && (step.kind == .Messages || step.kind == .Pictures || step.kind == .Files) {
		if over {
			db_meta_set(db, PURGE_META_BELOW, 0)
		} else {
			db_meta_set(db, PURGE_META_CURSOR, step.cursor)
		}
	}
	if !over {
		return
	}
	done = step^
	ordered_remove(&r.steps, 0)
	return done, true
}

// msg_bounds are the first and last messages' ids, 0 for none.
@(private = "file")
msg_bounds :: proc(db: ^DB) -> (first, last: proto.Msg_Id) {
	q := db_stmt(db, .Msg_Bounds)
	if row, ok := db_step(db, q); ok && row {
		first, last = proto.Msg_Id(db_col_int(q, 0)), proto.Msg_Id(db_col_int(q, 1))
		sqlite.reset(q)
	}
	return
}

@(private = "file")
Scanned :: struct {
	id:    proto.Msg_Id,
	conv:  proto.Conv_Id,
	flags: proto.Msg_Flags,
	size:  i64, // its picture's
}

// scan reads the next few messages a step goes through, past its cursor.
@(private = "file")
scan :: proc(db: ^DB, step: ^Purge_Step, all, one: Stmt, out: ^[PURGE_CHUNK]Scanned) -> (rows: []Scanned, ok: bool) {
	q := db_stmt(db, one if step.conv != 0 else all)
	db_bind_int(q, 1, step.cursor)
	db_bind_int(q, 2, i64(step.below))
	db_bind_int(q, 3, PURGE_CHUNK)
	if step.conv != 0 {
		db_bind_int(q, 4, i64(step.conv))
	}
	n := 0
	for {
		row := db_step(db, q) or_return
		if !row {
			break
		}
		out[n] = {
			id    = proto.Msg_Id(db_col_int(q, 0)),
			conv  = proto.Conv_Id(db_col_int(q, 1)),
			flags = transmute(proto.Msg_Flags)u8(db_col_int(q, 2)),
			size  = db_col_int(q, 3),
		}
		n += 1
	}
	return out[:n], true
}

// run_on runs a statement that writes, with ids for its parameters.
@(private = "file")
run_on :: proc(db: ^DB, stmt: Stmt, args: ..i64) -> bool {
	q := db_stmt(db, stmt)
	for a, i in args {
		db_bind_int(q, i + 1, a)
	}
	return db_run(db, q)
}

/*
purge_messages_chunk removes the next few messages below the step's
boundary; true when there are none left to look at. A failure ends the
step, logged: what's left stays, and the next run tries again.
*/
@(private = "file")
purge_messages_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Scan, .Purge_Scan_Conv, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if .Has_Thread in m.flags {
			kept := .Pinned in m.flags
			if !kept {
				q := db_stmt(db, .Purge_Reply_Kept)
				db_bind_int(q, 1, i64(m.id))
				db_bind_int(q, 2, i64(step.below))
				row, stepped := db_step(db, q)
				if row {
					sqlite.reset(q)
				}
				kept = row || !stepped
			}
			if kept {
				// Some of its replies may go, which it counts.
				append(&step.roots, m.id)
				continue
			}
		}
		if .Pinned in m.flags {
			continue
		}
		id := i64(m.id)
		if !run_on(db, .Pin_Clear, i64(m.conv), id) ||
		   !run_on(db, .React_Clear, id) ||
		   !run_on(db, .Mention_Clear, id) ||
		   !run_on(db, .Msg_Remove, id) {
			log.errorf("could not purge message %d", id)
			return true
		}
		step.count += 1
		step.convs[m.conv] = true
	}
	return len(rows) < PURGE_CHUNK
}

// purge_pictures_chunk takes the pictures out of the next few messages
// below the step's boundary; true when it's done.
@(private = "file")
purge_pictures_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Pictures, .Purge_Pictures_Conv, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if .Pinned in m.flags {
			continue
		}
		if !run_on(db, .Msg_Strip_Picture, i64(m.id)) {
			log.errorf("could not take the picture out of message %d", m.id)
			return true
		}
		step.count += 1
		step.convs[m.conv] = true
	}
	return len(rows) < PURGE_CHUNK
}

// purge_files_chunk takes the files out of the next few messages below
// the step's boundary; true when it's done.
@(private = "file")
purge_files_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Files, .Purge_Files_Conv, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if .Pinned in m.flags {
			continue
		}
		if !run_on(db, .Attach_Strip, i64(m.id)) {
			log.errorf("could not take the files out of message %d", m.id)
			return true
		}
		step.count += 1
		step.convs[m.conv] = true
	}
	return len(rows) < PURGE_CHUNK
}

// purge_stored_chunk takes pictures and files out of the oldest messages
// until enough room is free; true when it's done.
@(private = "file")
purge_stored_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Stored, .Purge_Stored, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if .Pinned in m.flags {
			continue
		}
		if !run_on(db, .Msg_Strip_Picture, i64(m.id)) || !run_on(db, .Attach_Strip, i64(m.id)) {
			log.errorf("could not take what's stored out of message %d", m.id)
			return true
		}
		step.count += 1
		step.freed += m.size
		step.convs[m.conv] = true
		if step.bytes > 0 && step.freed >= step.bytes {
			// Enough: what's below this one is what went.
			step.below = m.id + 1
			return true
		}
	}
	return len(rows) < PURGE_CHUNK
}

/*
collect_chunk removes the next few blobs nothing uses; true when it has
looked at them all. The rows go first, committed, and then the files:
were the server stopped in between, a file without a row would only
take room, where a row without its file would be a blob that can't be
read.
*/
@(private = "file")
collect_chunk :: proc(bs: ^Blob_Store, step: ^Purge_Step, now_ms: i64) -> bool {
	db := bs.db
	Unused :: struct {
		id:   Blob_Id,
		hash: [BLOB_HASH_SIZE]u8,
	}
	unused: [PURGE_CHUNK]Unused
	n, seen := 0, 0
	q := db_stmt(db, .Blob_Scan)
	db_bind_int(q, 1, step.cursor)
	db_bind_int(q, 2, now_ms - BLOB_GRACE_MS)
	db_bind_int(q, 3, i64(step.keep))
	db_bind_int(q, 4, PURGE_CHUNK)
	for {
		row, ok := db_step(db, q)
		if !ok {
			return true
		}
		if !row {
			break
		}
		seen += 1
		id := db_col_int(q, 0)
		step.cursor = id
		if db_col_int(q, 2) != 0 && db_col_into(q, 1, unused[n].hash[:]) {
			unused[n].id = Blob_Id(id)
			n += 1
		}
	}
	for b in unused[:n] {
		if !run_on(db, .Blob_Delete, i64(b.id)) {
			log.errorf("could not remove blob %d", b.id)
			return true
		}
	}
	if n > 0 {
		db_commit(db)
	}
	for b in unused[:n] {
		path := blob_path(bs, b.hash)
		if err := os.remove(path); err != nil && os.exists(path) {
			log.warnf("could not remove %s: %v", path, err)
		}
		step.count += 1
	}
	return seen < PURGE_CHUNK
}

/*
The server's side: the hourly run, the Purge request, and telling
people.
*/

// retention_sync does what there is to do of retention this turn, if it
// may: at most RETENTION_BUDGET of it.
retention_sync :: proc(s: ^Server) {
	r := &s.retention
	if !r.ran || time.tick_since(r.last_run) >= RETENTION_INTERVAL {
		r.ran, r.last_run, r.due = true, time.tick_now(), true
	}
	// Not on top of what's still queued, such as the last run.
	if r.due && len(r.steps) == 0 {
		r.due = false
		retention_schedule(r, &s.db, unix_ms())
	}
	if len(r.steps) == 0 || time.tick_since(r.last_turn) < RETENTION_PAUSE {
		return
	}
	if s.db.log_pages >= RETENTION_LOG_PAGES {
		// This turn's share of the work. The log's file is cut back
		// when the loop is next idle (db_idle).
		db_checkpoint(&s.db, keep_file = true)
		r.last_turn = time.tick_now()
		return
	}
	started := time.tick_now()
	for len(r.steps) > 0 && time.tick_since(started) < RETENTION_BUDGET {
		step, finished := retention_chunk(r, &s.blobs, unix_ms())
		if finished {
			step_finished(s, &step)
			step_destroy(&step)
		}
		// Committed now, to know how long the log has grown.
		db_commit(&s.db)
		if s.db.log_pages >= RETENTION_LOG_PAGES {
			break
		}
	}
	r.last_turn = time.tick_now()
}

// retention_busy is whether retention has work queued, for the loop to
// come round more often meanwhile (RETENTION_WAIT).
retention_busy :: proc(s: ^Server) -> bool {
	return len(s.retention.steps) > 0
}

// retention_drain does everything that's queued, all at once: for tests,
// and for the command line.
retention_drain :: proc(r: ^Retention, bs: ^Blob_Store, s: ^Server = nil) -> (messages, blobs: int) {
	for len(r.steps) > 0 {
		step, finished := retention_chunk(r, bs, unix_ms())
		if !finished {
			continue
		}
		switch step.kind {
		case .Messages, .Pictures, .Files, .Stored:
			messages += step.count
		case .Collect:
			blobs += step.count
		case .Size_Cap, .Vacuum:
		}
		if s != nil {
			step_finished(s, &step)
		} else if step.asked && step.kind == .Collect {
			r.asked = false
		}
		step_destroy(&step)
	}
	db_commit(bs.db)
	return
}

/*
step_finished tells whoever needs to know what a step did: the members
of each conversation it purged, those whose unread counts it may have
changed, and, once a purge somebody asked for is through, them.
*/
@(private = "file")
step_finished :: proc(s: ^Server, step: ^Purge_Step) {
	r := &s.retention
	switch step.kind {
	case .Messages, .Pictures, .Files, .Stored:
		// What clients are told went: pictures and files both, for room.
		whats: [2]proto.Purge_What
		n := 1
		noun := "messages"
		switch step.kind {
		case .Pictures:
			whats[0], noun = .Images, "pictures"
		case .Files:
			whats[0], noun = .Files, "messages' files"
		case .Stored:
			whats, n, noun = {.Images, .Files}, 2, "messages' pictures and files"
		case .Messages, .Size_Cap, .Collect, .Vacuum:
		}
		what := whats[0]
		if step.count > 0 {
			log.infof("purged %d %s below message %d in %d conversation(s)", step.count, noun, step.below, len(step.convs))
		}
		buf: [proto.MSGS_PURGED_SIZE]u8
		for id in step.convs {
			conv := conv_by_id(&s.convs, id)
			if conv == nil {
				continue
			}
			for member in conv.members {
				acc := s.accounts.by_id[member] or_else nil
				if acc == nil || len(acc.conns) == 0 {
					continue
				}
				for c in acc.conns {
					for w in whats[:n] {
						send_event(c, .Msgs_Purged, proto.encode_msgs_purged(&buf, {conv = id, before = step.below, what = w}))
					}
				}
				if what == .Messages {
					// What it hadn't read may have gone.
					send_read(s, acc, conv)
				}
			}
		}
		// Roots that stay, with fewer replies.
		for root in step.roots {
			if m, found := msg_by_id(s, root); found {
				if conv := conv_by_id(&s.convs, m.conv); conv != nil {
					thread_changed(s, conv, root)
				}
			}
		}
		if what == .Messages {
			// Offers of files whose messages went can't be taken up.
			gone := make([dynamic]proto.Msg_Id, context.temp_allocator)
			for id in s.file_offers {
				if id < step.below {
					if _, found := msg_by_id(s, id); !found {
						append(&gone, id)
					}
				}
			}
			for id in gone {
				forget_offer(s, id)
			}
		}
		if step.asked {
			r.messages += step.count
		}
	case .Collect:
		if step.count > 0 {
			log.infof("removed %d stored file(s) nothing uses", step.count)
		}
		if step.asked {
			r.blobs += step.count
			r.asked = false
			purge_answer(s)
		}
	case .Size_Cap, .Vacuum:
	}
}

// purge_answer answers whoever asked for the purge that's just finished,
// if they're still there.
@(private = "file")
purge_answer :: proc(s: ^Server) {
	r := &s.retention
	a := r.asker
	r.asker = {}
	if !a.waiting {
		return
	}
	u := conn_of(s, a.key)
	if u == nil || u.instance != a.instance {
		return
	}
	buf: [proto.PURGE_ANSWER_SIZE]u8
	respond(u, a.request, .Ok, proto.encode_purge_answer(&buf, r.messages, r.blobs))
}

// purge_request handles Purge: it's answered when the purge is done.
purge_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	p, ok := proto.decode_purge(body)
	if !ok {
		respond(u, id, .Invalid)
		return
	}
	if !can(u.account, .Purge) {
		respond(u, id, .Denied)
		return
	}
	if p.conv != 0 && conv_by_id(&s.convs, p.conv) == nil {
		respond(u, id, .Not_Found)
		return
	}
	if !retention_ask(&s.retention, &s.db, p, unix_ms()) {
		respond(u, id, .Conflict)
		return
	}
	s.retention.asker = {
		waiting  = true,
		key      = u.key,
		instance = u.instance,
		request  = id,
	}
	place := "every conversation"
	if conv := conv_by_id(&s.convs, p.conv); conv != nil {
		place = conv.name if conv.kind == .Channel else "a DM"
	}
	log.infof(
		"%s purges the %s of %s from before %d",
		conn_label(u),
		"pictures" if p.what == .Images else "messages",
		place,
		p.before,
	)
}
