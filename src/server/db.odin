package server

import "core:c"
import "core:log"
import "core:strings"
import "core:time"

import "sqlite"

// The server's database is a single SQLite file (yap.db in the data directory)
// that is only used by the server's main loop.
//
// That loop also relays voice, so nothing here may wait for the disk while
// somebody is talking:
//
//   - The database is in WAL mode with synchronous=NORMAL, so a commit appends
//     to the write-ahead log and returns immediately. Nothing is lost if the
//     server is killed, but if the machine loses power the last moments can be.
//   - All writes made in one turn of the loop share one transaction, which
//     db_begin opens for the first of them and db_commit closes at the end of
//     the turn.
//   - Moving the log into the database file (a checkpoint) is what waits for
//     the disk. SQLite would do it on some commit of its own choosing, but here
//     it is done when the loop has had nothing to do (see db_idle), or when the
//     log has grown past DB_LOG_MOST regardless.
//
// The file is opened exclusively for this process (locking_mode=EXCLUSIVE), so a
// second server started on the same data finds it busy and gives up instead of
// both servers taking turns writing.
//
// Statements are prepared once when the database is opened and are identified by
// Stmt. Using one looks like this:
//
//	q := db_stmt(db, .Blob_By_Id)
//	db_bind_int(q, 1, id)
//	if row, ok := db_step(db, q); ok && row {
//		size := db_col_int(q, 0)
//	}
//
// A write ends with db_run instead of db_step. The schema and how it changes
// between versions of the server are described in db_schema.odin.

DB_FILE :: "yap.db"
// The path of an in-memory database, used for tests.
DB_MEMORY :: ":memory:"

// A log that has been waiting this long is checkpointed the next time the loop
// is idle.
DB_CHECKPOINT_AFTER :: 30 * time.Second
// A log longer than this (in pages of 4 KB) is checkpointed at the next commit,
// whether the loop is idle or not, because it would only get slower otherwise.
DB_LOG_MOST :: 4096
// A checkpoint that takes longer than this is logged as a warning.
DB_CHECKPOINT_SLOW :: 50 * time.Millisecond

// The statements the server uses, each prepared once.
//
// The messages_thread index (like the other partial indexes) only covers rows
// with thread_root != 0, and SQLite won't use it for `thread_root = ?1` alone
// because it can't tell that a parameter isn't 0. That is why the queries by
// thread also say `AND thread_root != 0`. Without it, they would read through
// every message below or above the anchor.
Stmt :: enum {
	Meta_Get,
	Meta_Set,
	Meta_Delete_Like,
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
	Purge_Reply_Kept,
	Purge_Count,
	Purge_Count_Conv,
	Pin_Clear,
	Msg_Remove,
	Stored_Bytes,
	Purge_Count_Files,
	Purge_Count_Files_Conv,
	Purge_Files,
	Purge_Files_Conv,
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
	Account_Set_Digest,
	Msg_Newest,
	Digest_DMs,
	Digest_Unread,
	Digest_Mentions,
	Push_Sub_Put,
	Push_Sub_Others,
	Push_Sub_Drop,
	Push_Sub_Gone,
	Push_Subs_Of,
}

@(private = "file", rodata)
STMT_SQL := [Stmt]string {
	.Meta_Get               = "SELECT value FROM meta WHERE key = ?1",
	.Meta_Set               = "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = ?2",
	.Meta_Delete_Like       = "DELETE FROM meta WHERE key LIKE ?1",
	.Blob_Add               = "INSERT INTO blobs (sha256, size, kind, width, height, created, by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Blob_By_Id             = "SELECT sha256, size, kind, width, height, created FROM blobs WHERE id = ?1",
	.Blob_By_Hash           = "SELECT id FROM blobs WHERE sha256 = ?1",
	.Blob_Delete            = "DELETE FROM blobs WHERE id = ?1",
	.Account_Add            = "INSERT INTO accounts (username, display, pw_hash, pw_salt, pw_params, flags, created) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Account_All            = "SELECT id, username, display, flags, created, last_seen, status, status_until, coalesce(avatar, 0), activity, email, verify_code, verify_expires, digest_upto, coalesce((SELECT CAST(value AS TEXT) FROM settings s WHERE s.account = accounts.id AND s.key = 'email/digest'), ''), coalesce((SELECT CAST(value AS TEXT) FROM settings s WHERE s.account = accounts.id AND s.key = 'push/text'), ''), coalesce((SELECT CAST(value AS TEXT) FROM settings s WHERE s.account = accounts.id AND s.key = 'voice/shown'), '') FROM accounts ORDER BY id",
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
	.Device_Put             = "INSERT INTO devices (key, account, name, agent, created, last_seen) VALUES (?1, ?2, ?3, ?5, ?4, ?4) ON CONFLICT (key) DO UPDATE SET account = ?2, name = ?3, agent = ?5, created = ?4, last_seen = ?4",
	.Device_All             = "SELECT key, account, name, created, last_seen, agent FROM devices",
	.Device_Delete          = "DELETE FROM devices WHERE key = ?1",
	.Device_Set_Seen        = "UPDATE devices SET last_seen = ?2 WHERE key = ?1",
	.Conv_Add               = "INSERT INTO convs (kind, flags, name, topic, position, created, created_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
	.Conv_Add_DM            = "INSERT INTO convs (kind, a, b, created, created_by) VALUES (1, ?1, ?2, ?3, ?4)",
	.Conv_All               = "SELECT id, kind, flags, name, topic, position, created, created_by, last_msg, a, b, COALESCE((SELECT time FROM messages WHERE id = convs.last_msg), 0) FROM convs ORDER BY id",
	.Member_Add             = "INSERT OR IGNORE INTO members (conv, account, joined, read_id) VALUES (?1, ?2, ?3, ?4)",
	.Member_Remove          = "DELETE FROM members WHERE conv = ?1 AND account = ?2",
	.Member_All             = "SELECT conv, account, read_id, notify FROM members",
	.Member_Set_Read        = "UPDATE members SET read_id = ?3 WHERE conv = ?1 AND account = ?2 AND read_id < ?3",
	.Member_Set_Notify      = "UPDATE members SET notify = ?3 WHERE conv = ?1 AND account = ?2",
	.Msg_Unread             = "SELECT count(*) FROM (SELECT 1 FROM messages WHERE conv = ?1 AND id > ?2 AND sender != ?3 AND flags & 1 = 0 LIMIT 100)",
	.Conv_Set_Last          = "UPDATE convs SET last_msg = ?2 WHERE id = ?1",
	.Msg_Add                = "INSERT INTO messages (conv, sender, time, kind, text, nonce, file_size, thread_root, flags, fwd_sender, fwd_conv, fwd_time) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
	.Msg_By_Nonce           = "SELECT id, time FROM messages WHERE sender = ?1 AND nonce = ?2",
	.Msg_Before             = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m WHERE m.conv = ?1 AND m.id < ?2 ORDER BY m.id DESC LIMIT ?3",
	.Msg_After              = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m WHERE m.conv = ?1 AND m.id > ?2 ORDER BY m.id LIMIT ?3",
	.Msg_Any_Before         = "SELECT 1 FROM messages WHERE conv = ?1 AND id < ?2 LIMIT 1",
	.Msg_Any_After          = "SELECT 1 FROM messages WHERE conv = ?1 AND id > ?2 LIMIT 1",
	.Thread_Before          = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m WHERE m.thread_root = ?1 AND m.thread_root != 0 AND m.id < ?2 ORDER BY m.id DESC LIMIT ?3",
	.Thread_After           = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m WHERE m.thread_root = ?1 AND m.thread_root != 0 AND m.id > ?2 ORDER BY m.id LIMIT ?3",
	.Thread_Any_Before      = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id < ?2 LIMIT 1",
	.Thread_Any_After       = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id > ?2 LIMIT 1",
	.Thread_Recount         = "UPDATE messages SET reply_count = (SELECT count(*) FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND flags & 1 = 0), last_reply = coalesce((SELECT max(id) FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND flags & 1 = 0), 0), flags = CASE WHEN EXISTS (SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0) THEN flags | 4 ELSE flags & ~4 END WHERE id = ?1",
	.Msg_Posted_In          = "SELECT 1 FROM messages WHERE conv = ?1 AND sender = ?2 LIMIT 1",
	.Msg_By_Id              = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages m WHERE m.id = ?1",
	.Msg_Edit               = "UPDATE messages SET text = ?2, edited = ?3 WHERE id = ?1",
	// Marks the message as deleted, and as neither pinned nor having files.
	.Msg_Delete             = "UPDATE messages SET flags = (flags | 1) & ~18, text = NULL, file_size = 0 WHERE id = ?1",
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
	.Pins_Of                = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM pins p JOIN messages m ON m.id = p.message WHERE p.conv = ?1 ORDER BY p.time DESC, p.message DESC LIMIT ?2",
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
	.Msg_Search             = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM messages_fts f CROSS JOIN messages m ON m.id = f.rowid WHERE messages_fts MATCH ?1 AND f.rowid < ?2 ORDER BY f.rowid DESC",
	.Reactors_Of            = "SELECT account FROM reactions WHERE message = ?1 AND emoji = ?2 ORDER BY time, account LIMIT ?3",
	.Msg_Bounds             = "SELECT coalesce((SELECT min(id) FROM messages), 0), coalesce((SELECT max(id) FROM messages), 0)",
	.Msg_From               = "SELECT id, time FROM messages WHERE id >= ?1 ORDER BY id LIMIT 1",
	.Purge_Scan             = "SELECT m.id, m.conv, m.flags, 0 FROM messages m WHERE m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Scan_Conv        = "SELECT m.id, m.conv, m.flags, 0 FROM messages m WHERE m.conv = ?4 AND m.id > ?1 AND m.id < ?2 ORDER BY m.id LIMIT ?3",
	.Purge_Reply_Kept       = "SELECT 1 FROM messages WHERE thread_root = ?1 AND thread_root != 0 AND id >= ?2 LIMIT 1",
	.Purge_Count            = "SELECT count(*) FROM messages WHERE id < ?1",
	.Purge_Count_Conv       = "SELECT count(*) FROM messages WHERE conv = ?2 AND id < ?1",
	.Pin_Clear              = "DELETE FROM pins WHERE conv = ?1 AND message = ?2",
	.Msg_Remove             = "DELETE FROM messages WHERE id = ?1",
	// The space taken by the pictures and files of messages.
	.Stored_Bytes           = "SELECT coalesce(sum(size), 0) FROM blobs WHERE kind = 4",
	// The messages that have files, and how big those files are.
	.Purge_Count_Files      = "SELECT count(DISTINCT a.msg) FROM attachments a WHERE a.blob IS NOT NULL AND a.msg < ?1",
	.Purge_Count_Files_Conv = "SELECT count(DISTINCT a.msg) FROM attachments a JOIN messages m ON m.id = a.msg WHERE a.blob IS NOT NULL AND a.msg < ?1 AND m.conv = ?2",
	.Purge_Files            = "SELECT m.id, m.conv, m.flags, coalesce((SELECT sum(b.size) FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.msg = m.id), 0) FROM messages m WHERE m.id > ?1 AND m.id < ?2 AND m.flags & 16 AND EXISTS (SELECT 1 FROM attachments WHERE msg = m.id AND blob IS NOT NULL) ORDER BY m.id LIMIT ?3",
	.Purge_Files_Conv       = "SELECT m.id, m.conv, m.flags, coalesce((SELECT sum(b.size) FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.msg = m.id), 0) FROM messages m WHERE m.conv = ?4 AND m.id > ?1 AND m.id < ?2 AND m.flags & 16 AND EXISTS (SELECT 1 FROM attachments WHERE msg = m.id AND blob IS NOT NULL) ORDER BY m.id LIMIT ?3",
	.Attach_Strip           = "UPDATE attachments SET blob = NULL WHERE msg = ?1",
	.Blob_Scan              = "SELECT id, sha256, created < ?2 AND id != ?3 AND NOT EXISTS (SELECT 1 FROM accounts WHERE avatar = blobs.id) AND NOT EXISTS (SELECT 1 FROM attachments WHERE blob = blobs.id) AND NOT EXISTS (SELECT 1 FROM meta WHERE key = 'server_icon' AND value = blobs.id) AND NOT EXISTS (SELECT 1 FROM meta WHERE key LIKE 'emoji_frames_%' AND value = blobs.id) FROM blobs WHERE id > ?1 ORDER BY id LIMIT ?4",
	.Blob_Touch             = "UPDATE blobs SET created = ?2 WHERE id = ?1",
	.Attach_Add             = "INSERT INTO attachments (msg, idx, blob, name, size) VALUES (?1, ?2, ?3, ?4, ?5)",
	.Attach_Of_Msg          = "SELECT blob, name, size FROM attachments WHERE msg = ?1 ORDER BY idx",
	.Attach_Clear           = "DELETE FROM attachments WHERE msg = ?1",
	.Attach_Blob_Convs      = "SELECT DISTINCT m.conv FROM attachments a JOIN messages m ON m.id = a.msg WHERE a.blob = ?1",
	.Files_Index_Add        = "INSERT INTO files_fts (rowid, names) VALUES (?1, ?2)",
	.Files_Index_Remove     = "DELETE FROM files_fts WHERE rowid = ?1",
	// Like Msg_Search, but searches the names of the files attached to messages.
	.File_Search            = "SELECT m.id, m.conv, m.sender, m.time, m.kind, m.flags, m.thread_root, m.edited, m.text, m.reply_count, m.last_reply, m.file_size, m.fwd_sender, m.fwd_conv, m.fwd_time FROM files_fts f CROSS JOIN messages m ON m.id = f.rowid WHERE files_fts MATCH ?1 AND f.rowid < ?2 ORDER BY f.rowid DESC",
	// What is left of a deleted account (see account_erase): a name nobody can
	// log in with, and nothing else.
	.Account_Erase          = "UPDATE accounts SET username = ?2, display = ?3, flags = ?4, status = '', status_until = 0, avatar = NULL, activity = 0, email = '', verify_code = '', verify_expires = 0, pw_hash = zeroblob(32) WHERE id = ?1",
	.Device_Erase           = "DELETE FROM devices WHERE account = ?1",
	.Buddy_Erase            = "DELETE FROM buddies WHERE account = ?1 OR buddy = ?1",
	.Setting_Erase          = "DELETE FROM settings WHERE account = ?1",
	.Mention_Erase          = "DELETE FROM mentions WHERE account = ?1",
	.Member_Erase           = "DELETE FROM members WHERE account = ?1",
	.Invite_Erase           = "UPDATE invites SET revoked = 1 WHERE creator = ?1",
	// Emailing accounts what they missed (see digest.odin).
	.Account_Set_Digest     = "UPDATE accounts SET digest_upto = ?2 WHERE id = ?1",
	.Msg_Newest             = "SELECT coalesce(max(id), 0) FROM messages",
	// The unread messages of account ?1 in the DMs it gets notifications from,
	// after message ?2 and posted after ?3, at most ?4 of them.
	.Digest_DMs             = "SELECT m.id, m.conv, m.sender, m.time, m.text, m.flags FROM members x JOIN convs c ON c.id = x.conv JOIN messages m ON m.conv = x.conv AND m.id > max(x.read_id, ?2) WHERE x.account = ?1 AND c.kind = 1 AND x.notify != 2 AND m.sender != ?1 AND m.time > ?3 AND m.flags & 1 = 0 ORDER BY m.id LIMIT ?4",
	// The same for every conversation where the account is notified of every
	// message, except archived channels.
	.Digest_Unread          = "SELECT m.id, m.conv, m.sender, m.time, m.text, m.flags FROM members x JOIN convs c ON c.id = x.conv JOIN messages m ON m.conv = x.conv AND m.id > max(x.read_id, ?2) WHERE x.account = ?1 AND c.flags & 4 = 0 AND x.notify = 0 AND m.sender != ?1 AND m.time > ?3 AND m.flags & 1 = 0 ORDER BY m.id LIMIT ?4",
	.Digest_Mentions        = "SELECT m.id, m.conv, m.sender, m.time, m.text, m.flags FROM mentions y JOIN members x ON x.conv = y.conv AND x.account = y.account JOIN messages m ON m.id = y.message WHERE y.account = ?1 AND y.message > max(x.read_id, ?2) AND x.notify != 2 AND m.time > ?3 AND m.flags & 1 = 0 ORDER BY m.id LIMIT ?4",
	// Web Push subscriptions (push_subs.odin).
	.Push_Sub_Put           = "INSERT INTO push_subs (device, account, endpoint, p256dh, auth, created) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (endpoint) DO UPDATE SET device = ?1, account = ?2, p256dh = ?4, auth = ?5, created = ?6",
	.Push_Sub_Others        = "DELETE FROM push_subs WHERE device = ?1 AND endpoint != ?2",
	.Push_Sub_Drop          = "DELETE FROM push_subs WHERE device = ?1",
	.Push_Sub_Gone          = "DELETE FROM push_subs WHERE id = ?1",
	.Push_Subs_Of           = "SELECT id, endpoint, p256dh, auth, device FROM push_subs WHERE account = ?1 ORDER BY id",
}

DB :: struct {
	conn:            ^sqlite.Connection,
	stmts:           [Stmt]^sqlite.Stmt,
	// Whether a transaction is open, meaning that something was written this
	// turn.
	in_tx:           bool,
	// The length of the log in pages as of the last commit, and when it was
	// last checkpointed.
	log_pages:       int,
	last_checkpoint: time.Tick,
}

// unix_ms returns the current time in the form the database stores it, which is
// milliseconds since the Unix epoch.
unix_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// db_open opens the database at `path`, creating it if it doesn't exist, and
// brings its schema up to date. Any failure is logged. `db` must stay where it is
// until db_close is called.
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

	// The lock is taken the first time the file is touched, which is the next
	// statement. That is where it shows if another server has the file open.
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
	// messages are purged) if the file was set up for it, and that has to be
	// requested before the first table is created.
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

// db_plan returns how SQLite would run one of the statements, as the lines of
// EXPLAIN QUERY PLAN joined by " | ". The result is allocated with the temp
// allocator. This is meant for tests.
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

// db_close commits any open transaction and closes the database, which also
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

// SQLite calls this after each commit with the current length of the log.
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

// db_error returns the message of the last error reported by SQLite.
db_error :: proc(db: ^DB) -> string {
	if db.conn == nil {
		return "out of memory"
	}
	return string(sqlite.errmsg(db.conn))
}

// db_exec runs SQL that has no parameters and returns no rows, such as pragmas
// and the schema. Any error is logged.
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

// db_pragma_int reads a pragma (or any statement) that answers with a single
// number. It returns SQLite's result code because db_open has to tell a busy
// database from a broken one. Nothing is logged.
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

// db_begin opens this turn's transaction if it isn't open yet. Everything that
// writes calls it first (db_run does), and the loop closes the transaction with
// db_commit.
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
		// The transaction can't be left open, because the writes of the next turn
		// would fail the same way.
		db_exec(db, "ROLLBACK")
		return
	}
	if db.log_pages >= DB_LOG_MOST {
		db_checkpoint(db)
	}
}

// db_idle is called when the loop has nothing to do, which is a good moment for
// work that waits for the disk.
db_idle :: proc(db: ^DB) {
	if db.log_pages > 0 && time.tick_since(db.last_checkpoint) >= DB_CHECKPOINT_AFTER {
		db_checkpoint(db)
	}
}

// db_checkpoint moves the log into the database file and empties it. With
// `keep_file`, the log's file keeps its size and is written over from the start,
// which saves the time that truncating it takes. This is useful when another
// checkpoint follows soon.
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
		// This is worth a warning because it is the one operation here that holds
		// up the loop for as long as the disk takes.
		log.warnf("database: checkpointing %d pages took %.1f ms", pages, ms)
	} else {
		log.debugf("database: checkpointed %d pages in %.1f ms", pages, ms)
	}
}

// db_open_reads returns how many statements hold a read open, meaning they were
// stepped to a row and not reset since. Between turns of the loop there should be
// none, because otherwise checkpoints can't finish ("database table is locked").
db_open_reads :: proc(db: ^DB) -> (n: int) {
	for s in db.stmts {
		if s != nil && sqlite.stmt_busy(s) != 0 {
			n += 1
		}
	}
	return
}

// db_stmt returns a prepared statement that is ready for its parameters.
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
	// An empty string has no address, and passing no address would bind NULL.
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

// db_step moves a query to its next row. `row` says whether there is one, whose
// columns can be read with the db_col procedures. Without a row, the query is
// finished. `ok` is false if the query failed, which is logged.
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

// db_run runs a statement that writes, as part of this turn's transaction.
@(require_results)
db_run :: proc(db: ^DB, s: ^sqlite.Stmt) -> bool {
	db_begin(db)
	row, ok := db_step(db, s)
	if row {
		sqlite.reset(s)
	}
	return ok
}

// db_last_id returns the id that the last INSERT gave its row.
db_last_id :: proc(db: ^DB) -> i64 {
	return sqlite.last_insert_rowid(db.conn)
}

// db_changed returns the number of rows that the last statement wrote or removed.
db_changed :: proc(db: ^DB) -> int {
	return int(sqlite.changes(db.conn))
}

// Columns are numbered from 0. Text and blobs are copied, because the memory that
// SQLite hands out is invalidated by the next step.

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

// db_col_into copies a blob column into `out` and returns whether the blob was
// exactly as long as `out`, as it is for a hash or a key.
db_col_into :: proc(s: ^sqlite.Stmt, column: int, out: []u8) -> bool {
	data := ([^]u8)(sqlite.column_blob(s, c.int(column)))
	n := int(sqlite.column_bytes(s, c.int(column)))
	if data == nil || n != len(out) {
		return false
	}
	copy(out, data[:n])
	return true
}

// db_meta reads one of the database's own metadata values.
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

// db_meta_text is like db_meta for a text value. The result is allocated with the
// temp allocator.
db_meta_text :: proc(db: ^DB, key: string) -> (value: string, found: bool) {
	q := db_stmt(db, .Meta_Get)
	db_bind_text(q, 1, key)
	if row, ok := db_step(db, q); ok && row {
		value = db_col_text(q, 0)
		sqlite.reset(q)
		return value, true
	}
	return
}

db_meta_set_text :: proc(db: ^DB, key: string, value: string) -> bool {
	q := db_stmt(db, .Meta_Set)
	db_bind_text(q, 1, key)
	db_bind_text(q, 2, value)
	return db_run(db, q)
}
