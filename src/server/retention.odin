package server

import "core:log"
import "core:os"
import "core:time"

import "common:proto"
import "sqlite"

// Retention removes old data permanently (see src/common/proto/purge.odin).
//
// The limits from the config are applied automatically, at startup and once
// an hour after that. Messages older than `message_days` are removed, the
// files (see attachments.odin) of messages older than `file_days` are
// removed, and the oldest files are removed while the stored files take up
// more than `blob_megabytes`. An account with Permission.Purge can purge a
// conversation, or all of them, up to a given time (Purge). So can whoever
// runs the server, from the command line while the server is stopped (see
// cli_purge.odin). After each run and each purge, the stored files that nothing
// uses any more are removed and the space they took in the database is
// returned to the filesystem.
//
//	purge messages   Removes the messages together with their reactions,
//	                 mentions and pins. Pinned messages are kept, and so is
//	                 the root of a thread while any of its replies is kept.
//	purge files      The messages stay, and so does each file in a message's
//	                 file list, but with its blob set to NULL. Pinned
//	                 messages are kept.
//	purge stored     Removes files, starting with those of the oldest
//	                 messages, until enough space is free (blob_megabytes).
//	collect          Removes the blobs that nothing refers to (no message, no
//	                 account's picture, not the emoji sheet) and that are
//	                 older than an hour. The age limit keeps a blob that was
//	                 just uploaded for a message that isn't posted yet. The
//	                 database row is deleted and committed first, and then
//	                 the file.
//	vacuum           Returns the database's free pages to the filesystem, a
//	                 few at a time.
//
// All of this is done by the server's main loop, which also relays voice
// data. It is therefore done a little at a time: a few dozen rows, then
// another few dozen, using at most RETENTION_BUDGET per loop iteration, with
// other work in between. Nothing waits for it.
//
// Purges use message ids rather than times. A time is converted to the id
// of the first message posted at or after it (see msg_boundary), which
// works because ids increase with time. What a purge removes is then
// everything "below that id", which is also what clients are told to drop
// (Msgs_Purged).
//
// A purge of one author's messages (docs/design/moderation.md, D11 and D12)
// goes through that account's messages instead, from the first posted at or
// after its time up to the last one there was when it was asked for. It
// removes pinned messages too. A thread's root that has replies by others
// becomes a deleted message (as if deleted with Msg_Delete), so the thread
// stays readable, and a removed reply changes its thread's count. A ban's
// purge only goes through channels: DMs are the other person's too.
//
// A purge that somebody asked for is recorded in the database's meta table
// as it progresses, so that a server that is stopped in the middle of it
// continues it when it starts again. The hourly run doesn't need this
// because it simply starts over.

Retention_Config :: struct {
	message_days:   int,
	file_days:      int,
	blob_megabytes: int,
}

// How often the limits from the config are applied, and the maximum time
// that one loop iteration spends on retention. At least RETENTION_PAUSE
// must pass between such iterations so that other work gets done.
RETENTION_INTERVAL :: time.Hour
RETENTION_BUDGET :: 2 * time.Millisecond
RETENTION_PAUSE :: 2 * time.Millisecond
// The number of rows that are looked at at once.
PURGE_CHUNK :: 64
// A blob that nothing uses is kept for this long after it was stored.
BLOB_GRACE_MS :: 60 * 60 * 1000
// The number of free pages that are returned to the filesystem at once.
VACUUM_PAGES :: "32"
// Whatever purging writes goes through the database's log like any other
// write. If left alone, the log is moved into the database all at once when
// it has grown to DB_LOG_MOST, which takes tens of milliseconds. Instead,
// the retention work of a loop iteration ends once the log has this many
// pages (of 4 KB), and the next iteration is spent moving it into the
// database. This takes only a few milliseconds: about 1 ms plus 10
// microseconds per page.
RETENTION_LOG_PAGES :: 128
// How long the server's socket waits for a packet while retention has work
// to do. The loop continues this often even if nobody is connected, instead
// of only ten times a second.
RETENTION_WAIT :: 2 * time.Millisecond

DAY_MS :: 24 * 60 * 60 * 1000

// The meta keys that the database uses to store a purge that somebody asked
// for while it is in progress, and the emoji sheet that is in use (see
// emoji.odin) and its frames.
@(private = "file")
PURGE_META_WHAT :: "purge_what"
@(private = "file")
PURGE_META_CONV :: "purge_conv"
@(private = "file")
PURGE_META_BELOW :: "purge_below"
@(private = "file")
PURGE_META_CURSOR :: "purge_cursor"
// A purge of one author's messages: the account, the first message that may
// go, and whether only channels are purged.
@(private = "file")
PURGE_META_AUTHOR :: "purge_author"
@(private = "file")
PURGE_META_FROM :: "purge_from"
@(private = "file")
PURGE_META_CHANNELS :: "purge_channels"
EMOJI_SHEET_META :: "emoji_sheet"
// The frames of the animated emojis, one key each: this prefix followed by
// the blob's id (Blob_Scan keeps every blob named like this).
EMOJI_FRAMES_META :: "emoji_frames_"

Purge_Step_Kind :: enum u8 {
	Messages,
	Files,
	Stored, // remove files until `bytes` of them have gone
	Size_Cap, // becomes Stored if the files take too much space
	Collect,
	Vacuum,
}

Purge_Step :: struct {
	kind:     Purge_Step_Kind,
	conv:     proto.Conv_Id, // Messages, Files: 0 for every conversation
	below:    proto.Msg_Id, // Messages, Files, Stored: everything below this id is affected
	cursor:   i64, // the last message or blob that was looked at
	// Messages, Files: only this account's messages from `from` on (0: everyone's),
	// and only in channels if `channels`.
	author:   proto.Account_Id,
	from:     proto.Msg_Id,
	channels: bool,
	// Stored: stop once this many bytes have been removed (0 means to go on up to `below`).
	bytes:    i64,
	// Somebody asked for it. The purge is recorded until it is done, and
	// what it did is the answer.
	asked:    bool,
	// Collect: the emoji sheet, which is kept.
	keep:     Blob_Id,
	// The result: the number of messages removed or stripped of their
	// files, or of blobs removed. Also the conversations that changed and the
	// kept roots whose threads may have lost replies.
	count:    int,
	freed:    i64,
	convs:    map[proto.Conv_Id]bool,
	roots:    [dynamic]proto.Msg_Id,
	// The author's thread roots that became deleted messages.
	tombs:    [dynamic]proto.Msg_Id,
}

Retention :: struct {
	config:    Retention_Config,
	// The steps that are still to be done, the first being in progress.
	steps:     [dynamic]Purge_Step,
	// When the config was last applied. `ran` is false if that never
	// happened yet. `due` is set when it needs to be applied again as soon
	// as the queued steps are done.
	last_run:  time.Tick,
	ran:       bool,
	due:       bool,
	last_turn: time.Tick,
	// A purge that somebody asked for is in progress. The asker is answered
	// when it is done (if it is still connected), with what the purge did.
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

// retention_open sets retention up with the limits from the config, and
// resumes a purge that was asked for and hasn't finished.
retention_open :: proc(r: ^Retention, db: ^DB, config: Retention_Config) {
	r.config = config
	below, found := db_meta(db, PURGE_META_BELOW)
	if !found || below == 0 {
		return
	}
	what, _ := db_meta(db, PURGE_META_WHAT)
	conv, _ := db_meta(db, PURGE_META_CONV)
	cursor, _ := db_meta(db, PURGE_META_CURSOR)
	author, _ := db_meta(db, PURGE_META_AUTHOR)
	from, _ := db_meta(db, PURGE_META_FROM)
	channels, _ := db_meta(db, PURGE_META_CHANNELS)
	kind := step_kind(proto.Purge_What(what))
	append(
		&r.steps,
		Purge_Step {
			kind = kind,
			conv = proto.Conv_Id(conv),
			below = proto.Msg_Id(below),
			cursor = cursor,
			asked = true,
			author = proto.Account_Id(author),
			from = proto.Msg_Id(from),
			channels = channels != 0,
		},
	)
	append(&r.steps, Purge_Step{kind = .Collect, asked = true}, Purge_Step{kind = .Vacuum})
	r.asked = true
	log.infof("resuming the purge of %s below message %d", conv_label(proto.Conv_Id(conv)), below)
}

// step_kind returns the kind of step that purges `what`.
@(private = "file")
step_kind :: proc(what: proto.Purge_What) -> Purge_Step_Kind {
	switch what {
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
	delete(step.tombs)
	step^ = {}
}

@(private = "file")
conv_label :: proc(conv: proto.Conv_Id) -> string {
	return "every conversation" if conv == 0 else "a conversation"
}

// msg_boundary returns the id of the first message posted at or after `time`
// (Unix milliseconds), or one past the last message if there is none. The
// messages posted before `time` are therefore those below the returned id.
// It is found by bisection, which relies on ids increasing with time. If
// the clock went backwards now and then, the result is off by about as many
// messages.
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
	// Look for the first position whose next message isn't older than `time`.
	for lo < hi {
		mid := lo + (hi - lo) / 2
		q = db_query(db, .Msg_From, mid)
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

// retention_schedule queues the steps that the config asks for, as of
// `now_ms`. These are the messages, then the files, then the stored files
// that are left over, then the files over the size limit and the stored
// files that are left from them, and finally the database's free pages.
// Collecting and vacuuming are done even if no limits are set, because they
// only remove what nothing uses.
retention_schedule :: proc(r: ^Retention, db: ^DB, now_ms: i64) {
	c := r.config
	if c.message_days > 0 {
		below := msg_boundary(db, now_ms - i64(c.message_days) * DAY_MS)
		append(&r.steps, Purge_Step{kind = .Messages, below = below})
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

// retention_ask queues a purge that somebody asked for, ahead of the steps
// that the config asks for, and records it. A purge of one author's messages
// goes through only channels if `channels` (a ban's). Returns false if a
// purge is already in progress.
retention_ask :: proc(
	r: ^Retention,
	db: ^DB,
	p: proto.Purge,
	now_ms: i64,
	channels := false,
) -> bool {
	if r.asked {
		return false
	}
	step := Purge_Step {
		kind  = step_kind(p.what),
		conv  = p.conv,
		asked = true,
	}
	if p.author != 0 {
		// Everything of theirs from `since` on that is there now.
		_, last := msg_bounds(db)
		step.author, step.channels = p.author, channels
		step.from = msg_boundary(db, i64(p.since)) if p.since > 0 else 1
		step.below = last + 1
		step.cursor = i64(step.from) - 1
	} else {
		step.below = msg_boundary(db, min(i64(p.before), now_ms))
	}
	db_meta_set(db, PURGE_META_WHAT, i64(p.what))
	db_meta_set(db, PURGE_META_CONV, i64(p.conv))
	db_meta_set(db, PURGE_META_CURSOR, step.cursor)
	db_meta_set(db, PURGE_META_AUTHOR, i64(step.author))
	db_meta_set(db, PURGE_META_FROM, i64(step.from))
	db_meta_set(db, PURGE_META_CHANNELS, 1 if step.channels else 0)
	db_meta_set(db, PURGE_META_BELOW, i64(step.below))
	// Insert it after the step that is in progress, which may be only
	// partly done.
	at := min(1, len(r.steps))
	inject_at(
		&r.steps,
		at,
		step,
		Purge_Step{kind = .Collect, asked = true},
		Purge_Step{kind = .Vacuum},
	)
	r.asked = true
	r.messages, r.blobs = 0, 0
	return true
}

// retention_chunk does a little of the first step. When the step finishes it
// is removed from the queue and returned (`finished`), so that the caller can
// notify whoever needs to know and then destroy it.
retention_chunk :: proc(
	r: ^Retention,
	bs: ^Blob_Store,
	now_ms: i64,
) -> (
	done: Purge_Step,
	finished: bool,
) {
	if len(r.steps) == 0 {
		return
	}
	step := &r.steps[0]
	db := bs.db
	over: bool
	switch step.kind {
	case .Messages:
		over = purge_messages_chunk(db, step)
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
		log.infof(
			"files take %d MB, which is more than the limit of %d MB, so the oldest are removed",
			total / (1024 * 1024),
			r.config.blob_megabytes,
		)
		_, last := msg_bounds(db)
		step^ = {
			kind  = .Stored,
			below = last + 1,
			bytes = total - limit,
		}
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
	if step.asked && (step.kind == .Messages || step.kind == .Files) {
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

// msg_bounds returns the ids of the first and last message, or 0 if there are no messages.
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
	size:  i64, // the total size of its files
	root:  proto.Msg_Id, // its thread's root, if it is a reply
}

// scan reads the next few messages that a step goes through, after its
// cursor: with `all` in every conversation, `one` in the step's, and `author`
// the step's author's.
@(private = "file")
scan :: proc(
	db: ^DB,
	step: ^Purge_Step,
	all, one, author: Stmt,
	out: ^[PURGE_CHUNK]Scanned,
) -> (
	rows: []Scanned,
	ok: bool,
) {
	q: ^sqlite.Stmt
	switch {
	case step.author != 0:
		q = db_query(db, author, step.cursor, i64(step.below), PURGE_CHUNK)
		db_bind_int(q, 4, i64(step.author))
		db_bind_int(q, 5, i64(step.conv))
		db_bind_int(q, 6, 1 if step.channels else 0)
	case step.conv != 0:
		q = db_query(db, one, step.cursor, i64(step.below), PURGE_CHUNK)
		db_bind_int(q, 4, i64(step.conv))
	case:
		q = db_query(db, all, step.cursor, i64(step.below), PURGE_CHUNK)
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
			root  = proto.Msg_Id(db_col_int(q, 4)),
		}
		n += 1
	}
	return out[:n], true
}

// run_on runs a statement that writes, with ids as its parameters.
@(private = "file")
run_on :: proc(db: ^DB, stmt: Stmt, args: ..i64) -> bool {
	q := db_stmt(db, stmt)
	for a, i in args {
		db_bind_int(q, i + 1, a)
	}
	return db_run(db, q)
}

// purge_messages_chunk removes the next few messages below the step's
// boundary. It returns true when there are no more messages to look at. A
// failure is logged and ends the step. What is left stays and the next run
// tries again.
@(private = "file")
purge_messages_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Scan, .Purge_Scan_Conv, .Purge_Author_Scan, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if step.author != 0 {
			if !purge_author_message(db, step, m) {
				return true
			}
			continue
		}
		if .Has_Thread in m.flags {
			kept := .Pinned in m.flags
			if !kept {
				q := db_query(db, .Purge_Reply_Kept, i64(m.id), i64(step.below))
				row, stepped := db_step(db, q)
				if row {
					sqlite.reset(q)
				}
				kept = row || !stepped
			}
			if kept {
				// Some of its replies may be removed, which changes its reply count.
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

// purge_author_message removes one of the author's messages, pinned or not.
// A thread's root that has replies by others (or newer ones of theirs) becomes
// a deleted message instead. Returns false on a failure, which is logged.
@(private = "file")
purge_author_message :: proc(db: ^DB, step: ^Purge_Step, m: Scanned) -> bool {
	id := i64(m.id)
	if .Has_Thread in m.flags {
		q := db_query(db, .Purge_Reply_Other, id, i64(step.author), i64(step.below))
		row, stepped := db_step(db, q)
		if row {
			sqlite.reset(q)
		}
		if row || !stepped {
			if .Deleted in m.flags {
				return true // it already is one
			}
			if !run_on(db, .Msg_Delete, id) ||
			   !run_on(db, .Pin_Clear, i64(m.conv), id) ||
			   !run_on(db, .React_Clear, id) ||
			   !run_on(db, .Mention_Clear, id) ||
			   !run_on(db, .Attach_Clear, id) ||
			   !run_on(db, .Files_Index_Remove, id) {
				log.errorf("could not purge message %d", id)
				return false
			}
			append(&step.tombs, m.id)
			step.count += 1
			step.convs[m.conv] = true
			return true
		}
	}
	if !run_on(db, .Pin_Clear, i64(m.conv), id) ||
	   !run_on(db, .React_Clear, id) ||
	   !run_on(db, .Mention_Clear, id) ||
	   !run_on(db, .Msg_Remove, id) {
		log.errorf("could not purge message %d", id)
		return false
	}
	// A reply: its thread has one fewer.
	if m.root != 0 {
		add_root(step, m.root)
	}
	step.count += 1
	step.convs[m.conv] = true
	return true
}

@(private = "file")
add_root :: proc(step: ^Purge_Step, root: proto.Msg_Id) {
	for r in step.roots {
		if r == root {
			return
		}
	}
	append(&step.roots, root)
}

// purge_files_chunk removes the files from the next few messages below the
// step's boundary. It returns true when it is done.
@(private = "file")
purge_files_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Files, .Purge_Files_Conv, .Purge_Author_Files, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		// An author's files go even from pinned messages.
		if .Pinned in m.flags && step.author == 0 {
			continue
		}
		if !run_on(db, .Attach_Strip, i64(m.id)) {
			log.errorf("could not remove the files from message %d", m.id)
			return true
		}
		step.count += 1
		step.convs[m.conv] = true
	}
	return len(rows) < PURGE_CHUNK
}

// purge_stored_chunk removes files from the oldest messages until enough
// space is free. It returns true when it is done.
@(private = "file")
purge_stored_chunk :: proc(db: ^DB, step: ^Purge_Step) -> bool {
	buf: [PURGE_CHUNK]Scanned
	rows, ok := scan(db, step, .Purge_Files, .Purge_Files, .Purge_Files, &buf)
	if !ok {
		return true
	}
	for m in rows {
		step.cursor = i64(m.id)
		if .Pinned in m.flags {
			continue
		}
		if !run_on(db, .Attach_Strip, i64(m.id)) {
			log.errorf("could not remove the stored files from message %d", m.id)
			return true
		}
		step.count += 1
		step.freed += m.size
		step.convs[m.conv] = true
		if step.bytes > 0 && step.freed >= step.bytes {
			// Enough space is free. Everything below this message was purged.
			step.below = m.id + 1
			return true
		}
	}
	return len(rows) < PURGE_CHUNK
}

// collect_chunk removes the next few blobs that nothing uses. It returns
// true when it has looked at all of them. The rows are deleted and committed
// first, and then the files are removed. If the server is stopped in
// between, a file without a row only takes up space, whereas a row without
// its file would be a blob that can't be read.
@(private = "file")
collect_chunk :: proc(bs: ^Blob_Store, step: ^Purge_Step, now_ms: i64) -> bool {
	db := bs.db
	Unused :: struct {
		id:   Blob_Id,
		hash: [BLOB_HASH_SIZE]u8,
	}
	unused: [PURGE_CHUNK]Unused
	n, seen := 0, 0
	q := db_query(db, .Blob_Scan, step.cursor, now_ms - BLOB_GRACE_MS, i64(step.keep), PURGE_CHUNK)
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

// The rest of this file is the server's side of retention: the hourly run,
// the Purge request and notifying the clients.

// retention_sync does the retention work for this loop iteration, if it is
// allowed to, using at most RETENTION_BUDGET.
retention_sync :: proc(s: ^Server) {
	r := &s.retention
	if !r.ran || time.tick_since(r.last_run) >= RETENTION_INTERVAL {
		r.ran, r.last_run, r.due = true, time.tick_now(), true
	}
	// Don't schedule it while steps are still queued, such as those of the last run.
	if r.due && len(r.steps) == 0 {
		r.due = false
		retention_schedule(r, &s.db, unix_ms())
	}
	if len(r.steps) == 0 || time.tick_since(r.last_turn) < RETENTION_PAUSE {
		return
	}
	if s.db.log_pages >= RETENTION_LOG_PAGES {
		// Moving the log into the database is this iteration's share of the
		// work. The log's file is truncated when the loop is next idle (see
		// db_idle).
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
		// Commit now to find out how far the log has grown.
		db_commit(&s.db)
		if s.db.log_pages >= RETENTION_LOG_PAGES {
			break
		}
	}
	r.last_turn = time.tick_now()
}

// retention_busy returns whether retention has work queued. While it does,
// the main loop iterates more often (see RETENTION_WAIT).
retention_busy :: proc(s: ^Server) -> bool {
	return len(s.retention.steps) > 0
}

// retention_drain does everything that is queued at once. It is used by the
// tests and by the command line.
retention_drain :: proc(
	r: ^Retention,
	bs: ^Blob_Store,
	s: ^Server = nil,
) -> (
	messages, blobs: int,
) {
	for len(r.steps) > 0 {
		step, finished := retention_chunk(r, bs, unix_ms())
		if !finished {
			continue
		}
		switch step.kind {
		case .Messages, .Files, .Stored:
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

// step_finished notifies whoever needs to know what a step did. These are
// the members of each conversation that it purged, those whose unread counts
// it may have changed and, once a purge that somebody asked for is through,
// the account that asked.
@(private = "file")
step_finished :: proc(s: ^Server, step: ^Purge_Step) {
	r := &s.retention
	switch step.kind {
	case .Messages, .Files, .Stored:
		// What the clients are told was removed. For the steps that free
		// space, that is the files.
		what, noun := proto.Purge_What.Messages, "messages"
		if step.kind != .Messages {
			what, noun = .Files, "messages' files"
		}
		if step.count > 0 && step.author != 0 {
			log.infof(
				"purged %d of account %d's %s from message %d on in %d conversation(s)",
				step.count,
				step.author,
				noun,
				step.from,
				len(step.convs),
			)
		} else if step.count > 0 {
			log.infof(
				"purged %d %s below message %d in %d conversation(s)",
				step.count,
				noun,
				step.below,
				len(step.convs),
			)
		}
		// The author's roots that are deleted messages now, kept for their
		// threads. Before Msgs_Purged, so that clients keep them (a deleted
		// root is never an author's message that went).
		for root in step.tombs {
			if m, found := msg_by_id(s, root); found {
				if conv := conv_by_id(&s.convs, m.conv); conv != nil {
					msg_deliver(s, conv, m, .Msg_Changed)
				}
			}
		}
		// With an author, `before` is 0, which older clients take as nothing.
		told := proto.Msgs_Purged {
			before = step.below,
			what   = what,
		}
		if step.author != 0 {
			told = {
				what   = what,
				author = step.author,
				from   = step.from,
			}
		}
		buf: [proto.MSGS_PURGED_MAX_SIZE]u8
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
				told.conv = id
				for c in acc.conns {
					send_event(c, .Msgs_Purged, proto.encode_msgs_purged(&buf, told))
				}
				if what == .Messages {
					// Messages that it hadn't read yet may have been removed.
					send_read(s, acc, conv)
				}
			}
		}
		// Roots that are kept but now have fewer replies.
		for root in step.roots {
			if m, found := msg_by_id(s, root); found {
				if conv := conv_by_id(&s.convs, m.conv); conv != nil {
					thread_changed(s, conv, root)
				}
			}
		}
		if what == .Messages {
			// Offered files whose messages were removed can no longer be accepted.
			gone := make([dynamic]proto.Msg_Id, context.temp_allocator)
			for id in s.file_offers {
				if id < step.below && id >= step.from {
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
			log.infof("removed %d stored file(s) that nothing uses", step.count)
		}
		if step.asked {
			r.blobs += step.count
			r.asked = false
			purge_answer(s)
		}
	case .Size_Cap, .Vacuum:
	}
}

// purge_answer answers the account that asked for the purge that just
// finished, if it is still connected.
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

// purge_request handles Purge. It is answered when the purge is done.
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
	if p.conv != 0 && conv_by_id(&s.convs, p.conv) == nil ||
	   p.author != 0 && account_by_id(&s.accounts, p.author) == nil {
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
	if author := account_by_id(&s.accounts, p.author); author != nil {
		log.infof(
			"%s purges %s's %s in %s from %d on",
			conn_label(u),
			author.username,
			"files" if p.what == .Files else "messages",
			place,
			p.since,
		)
		return
	}
	log.infof(
		"%s purges the %s of %s from before %d",
		conn_label(u),
		"files" if p.what == .Files else "messages",
		place,
		p.before,
	)
}
