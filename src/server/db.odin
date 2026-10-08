package server

import "core:c"
import "core:log"
import "core:strings"
import "core:time"

import "sqlite"

/*
The server's database: one SQLite file (yap.db in the data directory),
used only by the server's loop.

That loop also relays voice, so nothing here may wait for the disk while
somebody is talking:

  - The database is in WAL mode with synchronous=NORMAL: a commit appends
    to the write-ahead log and returns. If the server is killed nothing
    is lost; if the machine loses power, the last moments can be.
  - Writes made in one turn of the loop share one transaction, which
    db_begin opens for the first of them and db_commit closes at the end
    of the turn.
  - Moving the log into the database file (a checkpoint) is what does
    wait for the disk. SQLite would do it on some commit of its own
    choosing; here it's done when the loop has had nothing to do
    (db_idle), or when the log has grown past DB_LOG_MOST regardless.

The file is opened for this process alone (locking_mode=EXCLUSIVE), so
a second server started on the same data finds it busy and gives up
rather than the two of them taking turns writing.

Statements are prepared once, when the database is opened, and named by
Stmt. Using one goes:

	q := db_stmt(db, .Blob_By_Id)
	db_bind_int(q, 1, id)
	if row, ok := db_step(db, q); ok && row {
		size := db_col_int(q, 0)
	}

and a write ends in db_run instead of db_step. The schema and how it
changes from one version of the server to the next are in
db_schema.odin.
*/

DB_FILE :: "yap.db"
// An in-memory database, for tests.
DB_MEMORY :: ":memory:"

// A log that has been waiting this long is checkpointed the next time
// the loop is idle.
DB_CHECKPOINT_AFTER :: 30 * time.Second
// And one longer than this (in pages, of 4 KB) is checkpointed at the
// next commit, idle or not: left alone it would only get slower.
DB_LOG_MOST :: 4096
// A checkpoint that takes longer than this is logged as a warning.
DB_CHECKPOINT_SLOW :: 50 * time.Millisecond

/*
The statements the server uses, each prepared once.

messages_thread (like the other partial indexes) only covers rows with
thread_root != 0, and SQLite won't use it for `thread_root = ?1` alone:
it can't tell that a parameter isn't 0. So the queries by thread say
`AND thread_root != 0` too; without it they read through every message
below or above the anchor.
*/
Stmt :: enum {
	Meta_Get,
	Meta_Set,
	Blob_Add,
	Blob_By_Id,
	Blob_By_Hash,
	Blob_Delete,
	Account_Add,
	Account_All,
	Account_Secret,
	Account_Set_Password,
	Account_Set_Display,
	Account_Set_Status,
	Account_Set_Avatar,
	Setting_All,
	Setting_Put,
	Setting_Delete,
	Setting_Count,
	Setting_Has,
	Account_Set_Flags,
	Account_Set_Seen,
	Device_Put,
	Device_All,
	Device_Delete,
	Device_Set_Seen,
	Conv_Add,
	Conv_Add_DM,
	Conv_All,
	Member_Add,
	Member_Remove,
	Member_All,
	Member_Set_Read,
	Member_Set_Notify,
	Msg_Unread,
	Conv_Set_Last,
	Msg_Add,
	Msg_By_Nonce,
	Msg_Before,
	Msg_After,
	Msg_Any_Before,
	Msg_Any_After,
	Thread_Before,
	Thread_After,
	Thread_Any_Before,
	Thread_Any_After,
	Thread_Recount,
	Msg_Blob_Convs,
	Msg_Posted_In,
	Msg_By_Id,
	Msg_Edit,
	Msg_Delete,
	Msg_Set_Flags,
	Pin_Add,
	Pin_Remove,
	Pin_Count,
	Pins_Of,
	Mention_Add,
	Mention_Clear,
	Mentioned_In,
	Mention_Count,
	React_Add,
	React_Remove,
	React_Count,
	React_Kinds,
	Reactions_Of,
	React_Clear,
	Buddy_All,
	Role_All,
	Role_Add,
	Role_Update,
	Role_Set_Position,
	Role_Delete,
	Role_Unassign_All,
	Account_Role_All,
	Account_Roles_Clear,
	Account_Role_Add,
	Conv_Update,
	Conv_Set_Flags,
	Buddy_Add,
	Buddy_Remove,
	Account_Set_Activity,
	Account_Set_Email,
	Account_Set_Verify,
	Invite_Add,
	Invite_Get,
	Invite_All,
	Invite_Mine,
	Invite_Live_Count,
	Invite_Revoke,
	Invite_Use,
	Invite_Use_Add,
	Invite_Of,
	Msg_Search,
	Reactors_Of,
	Msg_Bounds,
	Msg_From,
	Purge_Scan,
	Purge_Scan_Conv,
	Purge_Pictures,
	Purge_Pictures_Conv,
	Purge_Reply_Kept,
	Purge_Count,
	Purge_Count_Conv,
	Pin_Clear,
	Msg_Remove,
	Msg_Strip_Picture,
	Stored_Bytes,
	Purge_Count_Files,
	Purge_Count_Files_Conv,
	Purge_Files,
	Purge_Files_Conv,
	Purge_Stored,
	Attach_Strip,
	Blob_Scan,
	Blob_Touch,
	Attach_Add,
	Attach_Of_Msg,
	Attach_Clear,
	Attach_Blob_Convs,
	Files_Index_Add,
	Files_Index_Remove,
	File_Search,
	Account_Erase,
	Device_Erase,
	Buddy_Erase,
	Setting_Erase,
	Mention_Erase,
	Member_Erase,
	Invite_Erase,
}

@(private = "file", rodata)
STMT_SQL := [Stmt]string {
	.Meta_Get               = "SELECT value FROM meta WHERE key = ?1",
	.Meta_Set               = "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = ?2",
	.Blob_Add               = "INSERT INTO blobs (sha256, size, kind, width, height, created, by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Blob_By_Id             = "SELECT sha256, size, kind, width, height, created FROM blobs WHERE id = ?1",
	.Blob_By_Hash           = "SELECT id FROM blobs WHERE sha256 = ?1",
	.Blob_Delete            = "DELETE FROM blobs WHERE id = ?1",
	.Account_Add            = "INSERT INTO accounts (username, display, pw_hash, pw_salt, pw_params, flags, created) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Account_All            = "SELECT id, username, display, flags, created, last_seen, status, status_until, coalesce(avatar, 0), activity, email, verify_code, verify_expires FROM accounts ORDER BY id",
	.Account_Secret         = "SELECT pw_hash, pw_salt, pw_params FROM accounts WHERE id = ?1",
	.Account_Set_Password   = "UPDATE accounts SET pw_hash = ?2, pw_salt = ?3, pw_params = ?4 WHERE id = ?1",
	.Account_Set_Display    = "UPDATE accounts SET display = ?2 WHERE id = ?1",
	.Account_Set_Status     = "UPDATE accounts SET status = ?2, status_until = ?3 WHERE id = ?1",
	.Account_Set_Avatar     = "UPDATE accounts SET avatar = ?2 WHERE id = ?1",
	.Setting_All            = "SELECT key, value FROM settings WHERE account = ?1 ORDER BY key",
	.Setting_Put            = "INSERT INTO settings (account, key, value) VALUES (?1, ?2, ?3) ON CONFLICT (account, key) DO UPDATE SET value = excluded.value",
	.Setting_Delete         = "DELETE FROM settings WHERE account = ?1 AND key = ?2",
	.Setting_Count          = "SELECT count(*) FROM settings WHERE account = ?1",
	.Setting_Has            = "SELECT 1 FROM settings WHERE account = ?1 AND key = ?2",
	.Account_Set_Flags      = "UPDATE accounts SET flags = ?2 WHERE id = ?1",
	.Account_Set_Seen       = "UPDATE accounts SET last_seen = ?2 WHERE id = ?1",
	.Device_Put             = "INSERT INTO devices (key, account, name, created, last_seen) VALUES (?1, ?2, ?3, ?4, ?4) ON CONFLICT (key) DO UPDATE SET account = ?2, name = ?3, created = ?4, last_seen = ?4",
	.Device_All             = "SELECT key, account, name, created, last_seen FROM devices",
	.Device_Delete          = "DELETE FROM devices WHERE key = ?1",
	.Device_Set_Seen        = "UPDATE devices SET last_seen = ?2 WHERE key = ?1",
	.Conv_Add               = "INSERT INTO convs (kind, flags, name, topic, position, created, created_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Conv_Add_DM            = "INSERT INTO convs (kind, a, b, created, created_by) VALUES (1, ?1, ?2, ?3, ?4)",
	.Conv_All               = "SELECT id, kind, flags, name, topic, position, created, created_by, last_msg, a, b FROM convs ORDER BY id",
	.Member_Add             = "INSERT OR IGNORE INTO members (conv, account, joined, read_id) VALUES (?1, ?2, ?3, ?4)",
	.Member_Remove          = "DELETE FROM members WHERE conv = ?1 AND account = ?2",
	.Member_All             = "SELECT conv, account, read_id, notify FROM members",
	.Member_Set_Read        = "UPDATE members SET read_id = ?3 WHERE conv = ?1 AND account = ?2 AND read_id < ?3",
	.Member_Set_Notify      = "UPDATE members SET notify = ?3 WHERE conv = ?1 AND account = ?2",
	.Msg_Unread             = "SELECT count(*) FROM (SELECT 1 FROM messages WHERE conv = ?1 AND id > ?2 AND sender != ?3 AND flags & 1 = 0 LIMIT 100)",
	.Conv_Set_Last          = "UPDATE convs SET last_msg = ?2 WHERE id = ?1",
	.Msg_Add                = "INSERT INTO messages (conv, sender, time, kind, text, blob, nonce, file_size, thread_root, flags, fwd_sender, fwd_conv, fwd_time) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
	.Msg_By_Nonce           = "SELECT id, time FROM messages WHERE sender = ?1 AND nonce = ?2",
	.Msg_Before             = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.conv = ?1 AND m.id < ?2 ORDER BY m.id DESC LIMIT ?3",
	.Msg_After              = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.conv = ?1 AND m.id > ?2 ORDER BY m.id LIMIT ?3",
	.Msg_Any_Before         = "SELECT 1 FROM messages WHERE conv = ?1 AND id < ?2 LIMIT 1",
	.Msg_Any_After          = "SELECT 1 FROM messages WHERE conv = ?1 AND id > ?2 LIMIT 1",
	.Thread_Before          = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.thread_root = ?1 AND m.thread_root != 0 AND m.id < ?2 ORDER BY m.id DESC LIMIT ?3",
	.Thread_After           = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.thread_root = ?1 AND m.thread_root != 0 AND m.id > ?2 ORDER BY m.id LIMIT ?3",
	.Thread_Any_Before      = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id < ?2 LIMIT 1",
	.Thread_Any_After       = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id > ?2 LIMIT 1",
	.Thread_Recount         = "UPDATE messages SET reply_count = (SELECT count(*) FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND flags & 1 = 0), last_reply = coalesce((SELECT max(id) FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND flags & 1 = 0), 0), flags = CASE WHEN EXISTS (SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0) THEN flags | 4 ELSE flags & ~4 END WHERE id = ?1",
	.Msg_Blob_Convs         = "SELECT DISTINCT conv FROM messages WHERE blob = ?1",
	.Msg_Posted_In          = "SELECT 1 FROM messages WHERE conv = ?1 AND sender = ?2 LIMIT 1",
	.Msg_By_Id              = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.id = ?1",
	.Msg_Edit               = "UPDATE messages SET text = ?2, edited = ?3 WHERE id = ?1",
	// Deleted, and neither pinned nor carrying files any more.
	.Msg_Delete             = "UPDATE messages SET flags = (flags | 1) & ~18, text = NULL, blob = NULL, file_size = 0 WHERE id = ?1",
	.Msg_Set_Flags          = "UPDATE messages SET flags = ?2 WHERE id = ?1",
	.Pin_Add                = "INSERT OR IGNORE INTO pins (conv, message, by, time) VALUES (?1, ?2, ?3, ?4)",
	.Pin_Remove             = "DELETE FROM pins WHERE conv = ?1 AND message = ?2",
	.Pin_Count              = "SELECT count(*) FROM pins WHERE conv = ?1",
	.Mention_Add            = "INSERT OR IGNORE INTO mentions (account, conv, message) VALUES (?1, ?2, ?3)",
	.Mention_Clear          = "DELETE FROM mentions WHERE message = ?1",
	.Mentioned_In           = "SELECT account FROM mentions WHERE message = ?1",
	.React_Add              = "INSERT OR IGNORE INTO reactions (message, emoji, account, time) VALUES (?1, ?2, ?3, ?4)",
	.React_Remove           = "DELETE FROM reactions WHERE message = ?1 AND emoji = ?2 AND account = ?3",
	.React_Count            = "SELECT count(*) FROM reactions WHERE message = ?1 AND emoji = ?2",
	.React_Kinds            = "SELECT count(DISTINCT emoji) FROM reactions WHERE message = ?1",
	.Reactions_Of           = "SELECT emoji, count(*), max(account = ?2) FROM reactions WHERE message = ?1 GROUP BY emoji ORDER BY min(time), emoji",
	.React_Clear            = "DELETE FROM reactions WHERE message = ?1",
	.Mention_Count          = "SELECT count(*) FROM (SELECT 1 FROM mentions WHERE account = ?1 AND conv = ?2 AND message > ?3 LIMIT 100)",
	.Pins_Of                = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM pins p JOIN messages m ON m.id = p.message LEFT JOIN blobs b ON b.id = m.blob WHERE p.conv = ?1 ORDER BY p.time DESC, p.message DESC LIMIT ?2",
	.Buddy_All              = "SELECT account, buddy FROM buddies",
	.Role_All               = "SELECT id, name, perms, color, position, flags FROM roles ORDER BY id",
	.Role_Add               = "INSERT INTO roles (name, perms, color, position, flags) VALUES (?1, ?2, ?3, ?4, ?5)",
	.Role_Update            = "UPDATE roles SET name = ?2, perms = ?3, color = ?4, flags = ?5 WHERE id = ?1",
	.Role_Set_Position      = "UPDATE roles SET position = ?2 WHERE id = ?1",
	.Role_Delete            = "DELETE FROM roles WHERE id = ?1",
	.Role_Unassign_All      = "DELETE FROM account_roles WHERE role = ?1",
	.Account_Role_All       = "SELECT account, role FROM account_roles ORDER BY account, role",
	.Account_Roles_Clear    = "DELETE FROM account_roles WHERE account = ?1",
	.Account_Role_Add       = "INSERT INTO account_roles (account, role) VALUES (?1, ?2)",
	.Conv_Update            = "UPDATE convs SET name = ?2, topic = ?3, position = ?4 WHERE id = ?1",
	.Conv_Set_Flags         = "UPDATE convs SET flags = ?2 WHERE id = ?1",
	.Buddy_Add              = "INSERT OR IGNORE INTO buddies (account, buddy) VALUES (?1, ?2)",
	.Buddy_Remove           = "DELETE FROM buddies WHERE account = ?1 AND buddy = ?2",
	.Account_Set_Activity   = "UPDATE accounts SET activity = ?2 WHERE id = ?1",
	.Account_Set_Email      = "UPDATE accounts SET email = ?2 WHERE id = ?1",
	.Account_Set_Verify     = "UPDATE accounts SET flags = ?2, verify_code = ?3, verify_expires = ?4 WHERE id = ?1",
	.Invite_Add             = "INSERT INTO invites (code, creator, created, max_uses, expires) VALUES (?1, ?2, ?3, ?4, ?5)",
	.Invite_Get             = "SELECT code, creator, created, max_uses, uses, expires, revoked FROM invites WHERE code = ?1",
	.Invite_All             = "SELECT code, creator, created, max_uses, uses, expires, revoked FROM invites ORDER BY rowid DESC LIMIT ?1",
	.Invite_Mine            = "SELECT code, creator, created, max_uses, uses, expires, revoked FROM invites WHERE creator = ?2 ORDER BY rowid DESC LIMIT ?1",
	.Invite_Live_Count      = "SELECT count(*) FROM invites WHERE creator = ?1 AND revoked = 0 AND (expires = 0 OR expires > ?2) AND (max_uses = 0 OR uses < max_uses)",
	.Invite_Revoke          = "UPDATE invites SET revoked = 1 WHERE code = ?1",
	.Invite_Use             = "UPDATE invites SET uses = uses + 1 WHERE code = ?1",
	.Invite_Use_Add         = "INSERT INTO invite_uses (code, account, used) VALUES (?1, ?2, ?3)",
	.Invite_Of              = "SELECT u.code, i.creator FROM invite_uses u JOIN invites i ON i.code = u.code WHERE u.account = ?1 ORDER BY u.used LIMIT 1",
	.Msg_Search             = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages_fts f CROSS JOIN messages m ON m.id = f.rowid LEFT JOIN blobs b ON b.id = m.blob WHERE messages_fts MATCH ?1 AND f.rowid < ?2 ORDER BY f.rowid DESC",
	.Reactors_Of            = "SELECT account FROM reactions WHERE message = ?1 AND emoji = ?2 ORDER BY time, account LIMIT ?3",
	.Msg_Bounds             = "SELECT coalesce((SELECT min(id) FROM messages), 0), coalesce((SELECT max(id) FROM messages), 0)",
	.Msg_From               = "SELECT id, time FROM messages WHERE id >= ?1 ORDER BY id LIMIT 1",
	.Purge_Scan             = "SELECT m.id, m.conv, m.flags, coalesce(b.size, 0) FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Scan_Conv        = "SELECT m.id, m.conv, m.flags, coalesce(b.size, 0) FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.conv = ?4 AND m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Pictures         = "SELECT m.id, m.conv, m.flags, coalesce(b.size, 0) FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.blob IS NOT NULL AND m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Pictures_Conv    = "SELECT m.id, m.conv, m.flags, coalesce(b.size, 0) FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.conv = ?4 AND m.blob IS NOT NULL AND m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Reply_Kept       = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id >= ?2 LIMIT 1",
	.Purge_Count            = "SELECT count(*), count(blob) FROM messages WHERE id < ?1",
	.Purge_Count_Conv       = "SELECT count(*), count(blob) FROM messages WHERE conv = ?2 AND id < ?1",
	.Pin_Clear              = "DELETE FROM pins WHERE conv = ?1 AND message = ?2",
	.Msg_Remove             = "DELETE FROM messages WHERE id = ?1",
	.Msg_Strip_Picture      = "UPDATE messages SET blob = NULL WHERE id = ?1",
	// What messages' pictures and files take.
	.Stored_Bytes           = "SELECT coalesce(sum(size), 0) FROM blobs WHERE kind IN (1, 4)",
	// Messages with files, and with pictures or files, and how big those are.
	.Purge_Count_Files      = "SELECT count(DISTINCT a.msg) FROM attachments a WHERE a.blob IS NOT NULL AND a.msg < ?1",
	.Purge_Count_Files_Conv = "SELECT count(DISTINCT a.msg) FROM attachments a JOIN messages m ON m.id = a.msg WHERE a.blob IS NOT NULL AND a.msg < ?1 AND m.conv = ?2",
	.Purge_Files            = "SELECT m.id, m.conv, m.flags, coalesce((SELECT sum(b.size) FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.msg = m.id), 0) FROM messages m WHERE m.id > ?1 AND m.id < ?2 AND m.flags & 16 AND EXISTS (SELECT 1 FROM attachments WHERE msg = m.id AND blob IS NOT NULL) ORDER BY m.id LIMIT ?3",
	.Purge_Files_Conv       = "SELECT m.id, m.conv, m.flags, coalesce((SELECT sum(b.size) FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.msg = m.id), 0) FROM messages m WHERE m.conv = ?4 AND m.id > ?1 AND m.id < ?2 AND m.flags & 16 AND EXISTS (SELECT 1 FROM attachments WHERE msg = m.id AND blob IS NOT NULL) ORDER BY m.id LIMIT ?3",
	.Purge_Stored           = "SELECT m.id, m.conv, m.flags, coalesce(b.size, 0) + coalesce((SELECT sum(fb.size) FROM attachments a JOIN blobs fb ON fb.id = a.blob WHERE a.msg = m.id), 0) FROM messages m LEFT JOIN blobs b ON b.id = m.blob WHERE m.id > ?1 AND m.id < ?2 AND (m.blob IS NOT NULL OR (m.flags & 16 AND EXISTS (SELECT 1 FROM attachments WHERE msg = m.id AND blob IS NOT NULL))) ORDER BY m.id LIMIT ?3",
	.Attach_Strip           = "UPDATE attachments SET blob = NULL WHERE msg = ?1",
	.Blob_Scan              = "SELECT id, sha256, created < ?2 AND id != ?3 AND NOT EXISTS (SELECT 1 FROM messages WHERE blob = blobs.id) AND NOT EXISTS (SELECT 1 FROM accounts WHERE avatar = blobs.id) AND NOT EXISTS (SELECT 1 FROM attachments WHERE blob = blobs.id) FROM blobs WHERE id > ?1 ORDER BY id LIMIT ?4",
	.Blob_Touch             = "UPDATE blobs SET created = ?2 WHERE id = ?1",
	.Attach_Add             = "INSERT INTO attachments (msg, idx, blob, name, size) VALUES (?1, ?2, ?3, ?4, ?5)",
	.Attach_Of_Msg          = "SELECT blob, name, size FROM attachments WHERE msg = ?1 ORDER BY idx",
	.Attach_Clear           = "DELETE FROM attachments WHERE msg = ?1",
	.Attach_Blob_Convs      = "SELECT DISTINCT m.conv FROM attachments a JOIN messages m ON m.id = a.msg WHERE a.blob = ?1",
	.Files_Index_Add        = "INSERT INTO files_fts (rowid, names) VALUES (?1, ?2)",
	.Files_Index_Remove     = "DELETE FROM files_fts WHERE rowid = ?1",
	// As Msg_Search, by the names of messages' files.
	.File_Search            = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.blob, b.width, b.height, b.size, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM files_fts f CROSS JOIN messages m ON m.id = f.rowid LEFT JOIN blobs b ON b.id = m.blob WHERE files_fts MATCH ?1 AND f.rowid < ?2 ORDER BY f.rowid DESC",
	// What's left of a deleted account (account_erase): a name nobody can
	// log in with, and nothing of its own.
	.Account_Erase          = "UPDATE accounts SET username = ?2, display = ?3, flags = ?4, status = '', status_until = 0, avatar = NULL, activity = 0, email = '', verify_code = '', verify_expires = 0, pw_hash = zeroblob(32) WHERE id = ?1",
	.Device_Erase           = "DELETE FROM devices WHERE account = ?1",
	.Buddy_Erase            = "DELETE FROM buddies WHERE account = ?1 OR buddy = ?1",
	.Setting_Erase          = "DELETE FROM settings WHERE account = ?1",
	.Mention_Erase          = "DELETE FROM mentions WHERE account = ?1",
	.Member_Erase           = "DELETE FROM members WHERE account = ?1",
	.Invite_Erase           = "UPDATE invites SET revoked = 1 WHERE creator = ?1",
}

DB :: struct {
	conn:            ^sqlite.Connection,
	stmts:           [Stmt]^sqlite.Stmt,
	// A transaction is open: something was written this turn.
	in_tx:           bool,
	// How long the log is, in pages, as of the last commit, and when it
	// was last checkpointed.
	log_pages:       int,
	last_checkpoint: time.Tick,
}

// unix_ms is the time as the database keeps it: milliseconds since the
// epoch.
unix_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

/*
db_open opens the database at `path`, creating it if it isn't there, and
brings its schema up to date. Whatever goes wrong is logged. `db` has to
stay where it is until db_close.
*/
@(require_results)
db_open :: proc(db: ^DB, path: string) -> bool {
	db^ = {}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if sqlite.open_v2(cpath, &db.conn, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE, nil) !=
	   sqlite.OK {
		log.errorf("could not open %s: %s", path, db_error(db))
		db_close(db)
		return false
	}

	// Ours alone from the first time the file is touched, which is the
	// next statement: that's where another server having it shows.
	if !db_exec(db, "PRAGMA locking_mode = EXCLUSIVE") {
		db_close(db)
		return false
	}
	version, rc := db_pragma_int(db, "PRAGMA user_version")
	if rc == sqlite.BUSY {
		log.errorf("%s is in use: is another yap-server running on it?", path)
		db_close(db)
		return false
	}
	if rc != sqlite.OK {
		log.errorf("could not read %s: %s", path, db_error(db))
		db_close(db)
		return false
	}

	// Freed pages can only be handed back to the filesystem (when old
	// messages are purged) if the file was laid out for it, and that has
	// to be asked for before its first table.
	if version == 0 && !db_exec(db, "PRAGMA auto_vacuum = INCREMENTAL") {
		db_close(db)
		return false
	}
	for pragma in ([]string {
			"PRAGMA journal_mode = WAL",
			"PRAGMA synchronous = NORMAL",
			"PRAGMA wal_autocheckpoint = 0",
			"PRAGMA foreign_keys = ON",
			"PRAGMA temp_store = MEMORY",
		}) {
		if !db_exec(db, pragma) {
			db_close(db)
			return false
		}
	}
	sqlite.wal_hook(db.conn, log_grew, db)
	db.last_checkpoint = time.tick_now()

	if !db_migrate(db, int(version), path) {
		db_close(db)
		return false
	}

	for sql, id in STMT_SQL {
		if sqlite.prepare_v2(db.conn, raw_data(sql), c.int(len(sql)), &db.stmts[id], nil) !=
		   sqlite.OK {
			log.errorf("could not prepare %v: %s", id, db_error(db))
			db_close(db)
			return false
		}
	}
	return true
}

// db_plan is how SQLite would run one of the statements: the lines of
// EXPLAIN QUERY PLAN, joined by " | ", in the temp allocator. For tests.
db_plan :: proc(db: ^DB, id: Stmt) -> string {
	sql := strings.concatenate({"EXPLAIN QUERY PLAN ", STMT_SQL[id]}, context.temp_allocator)
	q: ^sqlite.Stmt
	if sqlite.prepare_v2(db.conn, raw_data(sql), c.int(len(sql)), &q, nil) != sqlite.OK {
		return ""
	}
	defer sqlite.finalize(q)
	lines := make([dynamic]string, context.temp_allocator)
	for {
		row, ok := db_step(db, q)
		if !ok || !row {
			break
		}
		append(&lines, db_col_text(q, 3))
	}
	return strings.join(lines[:], " | ", context.temp_allocator)
}

// db_close commits what's open and closes the database, which also
// checkpoints it.
db_close :: proc(db: ^DB) {
	if db.conn == nil {
		return
	}
	db_commit(db)
	for &s in db.stmts {
		sqlite.finalize(s)
		s = nil
	}
	if rc := sqlite.close(db.conn); rc != sqlite.OK {
		log.errorf("could not close the database: %s", db_error(db))
	}
	db^ = {}
}

// SQLite calls this after each commit, with how long the log is now.
@(private = "file")
log_grew :: proc "c" (
	arg: rawptr,
	conn: ^sqlite.Connection,
	name: cstring,
	pages: c.int,
) -> c.int {
	(^DB)(arg).log_pages = int(pages)
	return sqlite.OK
}

// db_error is what SQLite says went wrong last.
db_error :: proc(db: ^DB) -> string {
	if db.conn == nil {
		return "out of memory"
	}
	return string(sqlite.errmsg(db.conn))
}

// db_exec runs SQL that has no parameters and gives no rows: pragmas,
// the schema. An error is logged.
db_exec :: proc(db: ^DB, sql: string) -> bool {
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	if rc := sqlite.exec(db.conn, csql, nil, nil, nil); rc != sqlite.OK {
		log.errorf("database: %s (%s)", db_error(db), first_line(sql))
		return false
	}
	return true
}

@(private = "file")
first_line :: proc(sql: string) -> string {
	s := strings.trim_space(sql)
	if i := strings.index_byte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// db_pragma_int reads a pragma (or any statement) that answers with one
// number. It returns SQLite's result code, as db_open has to tell busy
// from broken, and logs nothing.
db_pragma_int :: proc(db: ^DB, sql: string) -> (value: i64, rc: c.int) {
	s: ^sqlite.Stmt
	rc = sqlite.prepare_v2(db.conn, raw_data(sql), c.int(len(sql)), &s, nil)
	if rc != sqlite.OK {
		return
	}
	defer sqlite.finalize(s)
	rc = sqlite.step(s)
	if rc != sqlite.ROW {
		return
	}
	return sqlite.column_int64(s, 0), sqlite.OK
}

/*
db_begin opens this turn's transaction, if nothing has yet. Everything
that writes calls it first (db_run does), and the loop closes it with
db_commit.
*/
db_begin :: proc(db: ^DB) {
	if !db.in_tx && db_exec(db, "BEGIN") {
		db.in_tx = true
	}
}

// db_commit makes what this turn wrote permanent.
db_commit :: proc(db: ^DB) {
	if !db.in_tx {
		return
	}
	db.in_tx = false
	if !db_exec(db, "COMMIT") {
		// It can't be left open: what the next turn writes would go the
		// same way.
		db_exec(db, "ROLLBACK")
		return
	}
	if db.log_pages >= DB_LOG_MOST {
		db_checkpoint(db)
	}
}

// db_idle is the loop saying it has nothing to do: a good moment for
// what waits for the disk.
db_idle :: proc(db: ^DB) {
	if db.log_pages > 0 && time.tick_since(db.last_checkpoint) >= DB_CHECKPOINT_AFTER {
		db_checkpoint(db)
	}
}

/*
db_checkpoint moves the log into the database file and empties it.
`keep_file` leaves the log's file as long as it is, to be written over
from the start, which saves the time truncating it takes: for when
another checkpoint follows soon.
*/
db_checkpoint :: proc(db: ^DB, keep_file := false) {
	started := time.tick_now()
	pages := db.log_pages
	mode := c.int(sqlite.CHECKPOINT_PASSIVE if keep_file else sqlite.CHECKPOINT_TRUNCATE)
	if rc := sqlite.wal_checkpoint_v2(db.conn, nil, mode, nil, nil); rc != sqlite.OK {
		log.errorf("database: checkpoint failed: %s", db_error(db))
	}
	db.log_pages = 0
	db.last_checkpoint = time.tick_now()
	took := time.tick_diff(started, db.last_checkpoint)
	ms := time.duration_milliseconds(took)
	if took > DB_CHECKPOINT_SLOW {
		// Worth knowing about: this is the one thing here that holds the
		// loop up for as long as the disk takes.
		log.warnf("database: checkpointing %d pages took %.1f ms", pages, ms)
	} else {
		log.debugf("database: checkpointed %d pages in %.1f ms", pages, ms)
	}
}

// db_open_reads is how many statements hold a read open: stepped to a
// row and not reset since. Between turns of the loop it should be none,
// or checkpoints can't finish ("database table is locked").
db_open_reads :: proc(db: ^DB) -> (n: int) {
	for s in db.stmts {
		if s != nil && sqlite.stmt_busy(s) != 0 {
			n += 1
		}
	}
	return
}

// db_stmt is a prepared statement, ready for its parameters.
db_stmt :: proc(db: ^DB, id: Stmt) -> ^sqlite.Stmt {
	s := db.stmts[id]
	sqlite.reset(s)
	sqlite.clear_bindings(s)
	return s
}

// Parameters are numbered from 1, as in the SQL (?1, ?2, ...).

db_bind_int :: proc(s: ^sqlite.Stmt, index: int, value: i64) {
	sqlite.bind_int64(s, c.int(index), value)
}

db_bind_text :: proc(s: ^sqlite.Stmt, index: int, value: string) {
	// An empty string has no address to give, and none would mean NULL.
	empty: [1]u8
	text := raw_data(value) if len(value) > 0 else raw_data(empty[:])
	sqlite.bind_text(s, c.int(index), text, c.int(len(value)), sqlite.TRANSIENT)
}

db_bind_blob :: proc(s: ^sqlite.Stmt, index: int, value: []u8) {
	empty: u8
	data := rawptr(raw_data(value)) if len(value) > 0 else rawptr(&empty)
	sqlite.bind_blob(s, c.int(index), data, c.int(len(value)), sqlite.TRANSIENT)
}

db_bind_null :: proc(s: ^sqlite.Stmt, index: int) {
	sqlite.bind_null(s, c.int(index))
}

/*
db_step moves a query to its next row. `row` says there is one, whose
columns the db_col procedures read; without one the query is finished.
`ok` is false if it failed, which is logged.
*/
@(require_results)
db_step :: proc(db: ^DB, s: ^sqlite.Stmt) -> (row: bool, ok: bool) {
	switch rc := sqlite.step(s); rc {
	case sqlite.ROW:
		return true, true
	case sqlite.DONE:
		sqlite.reset(s)
		return false, true
	case:
		log.errorf("database: %s", db_error(db))
		sqlite.reset(s)
		return false, false
	}
}

// db_run runs a statement that writes, in this turn's transaction.
@(require_results)
db_run :: proc(db: ^DB, s: ^sqlite.Stmt) -> bool {
	db_begin(db)
	row, ok := db_step(db, s)
	if row {
		sqlite.reset(s)
	}
	return ok
}

// db_last_id is the id the last INSERT gave its row.
db_last_id :: proc(db: ^DB) -> i64 {
	return sqlite.last_insert_rowid(db.conn)
}

// db_changed is how many rows the last statement wrote or removed.
db_changed :: proc(db: ^DB) -> int {
	return int(sqlite.changes(db.conn))
}

// Columns are numbered from 0. Text and blobs are copied, since what
// SQLite hands out is gone with the next step.

db_col_int :: proc(s: ^sqlite.Stmt, column: int) -> i64 {
	return sqlite.column_int64(s, c.int(column))
}

db_col_null :: proc(s: ^sqlite.Stmt, column: int) -> bool {
	return sqlite.column_type(s, c.int(column)) == sqlite.NULL
}

db_col_text :: proc(s: ^sqlite.Stmt, column: int, allocator := context.temp_allocator) -> string {
	text := sqlite.column_text(s, c.int(column))
	n := int(sqlite.column_bytes(s, c.int(column)))
	if text == nil || n == 0 {
		return ""
	}
	return strings.clone(string(text[:n]), allocator)
}

db_col_blob :: proc(s: ^sqlite.Stmt, column: int, allocator := context.temp_allocator) -> []u8 {
	data := ([^]u8)(sqlite.column_blob(s, c.int(column)))
	n := int(sqlite.column_bytes(s, c.int(column)))
	if data == nil || n == 0 {
		return nil
	}
	out := make([]u8, n, allocator)
	copy(out, data[:n])
	return out
}

// db_col_into copies a blob column into `out` and says whether it was
// exactly that long: a hash, a key.
db_col_into :: proc(s: ^sqlite.Stmt, column: int, out: []u8) -> bool {
	data := ([^]u8)(sqlite.column_blob(s, c.int(column)))
	n := int(sqlite.column_bytes(s, c.int(column)))
	if data == nil || n != len(out) {
		return false
	}
	copy(out, data[:n])
	return true
}

// db_meta reads one of the database's own notes about itself.
db_meta :: proc(db: ^DB, key: string) -> (value: i64, found: bool) {
	q := db_stmt(db, .Meta_Get)
	db_bind_text(q, 1, key)
	if row, ok := db_step(db, q); ok && row {
		value = db_col_int(q, 0)
		sqlite.reset(q)
		return value, true
	}
	return
}

db_meta_set :: proc(db: ^DB, key: string, value: i64) -> bool {
	q := db_stmt(db, .Meta_Set)
	db_bind_text(q, 1, key)
	db_bind_int(q, 2, value)
	return db_run(db, q)
}
