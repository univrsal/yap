package server

import "core:fmt"
import "core:log"

// The database's schema, defined as the sequence of steps that created it.
//
// A database remembers how many of these steps it has been through (in SQLite's
// user_version). Opening a database runs the steps it hasn't seen yet, each in
// its own transaction. This way a server that is newer than its database brings
// the database up to date, and a server that stops halfway picks up where it
// left off.
//
// A step that has been released must never be changed, because a database that
// already went through it wouldn't see the change. Anything that needs changing
// gets a new step at the end.
//
// A database from a newer server, with steps this server doesn't know, is
// refused instead of guessed at.
//
// Times are Unix milliseconds. Ids are AUTOINCREMENT, so that the id of a row
// that was deleted is never given to another row.

@(private = "file", rodata)
MIGRATIONS := [?]string {
	// 1: the database's own metadata, and the blobs (see blobs.odin).
	`
	CREATE TABLE meta (
		key   TEXT PRIMARY KEY,
		value
	) WITHOUT ROWID;
	INSERT INTO meta (key, value) VALUES ('created', unixepoch() * 1000);

	CREATE TABLE blobs (
		id      INTEGER PRIMARY KEY AUTOINCREMENT,
		sha256  BLOB NOT NULL UNIQUE,
		size    INTEGER NOT NULL,
		kind    INTEGER NOT NULL,
		width   INTEGER NOT NULL DEFAULT 0,
		height  INTEGER NOT NULL DEFAULT 0,
		created INTEGER NOT NULL,
		by      INTEGER
	);
	`,
	// 2: accounts and the devices logged in to them (see auth.odin). The status
	// and avatar of an account are for later.
	`
	CREATE TABLE accounts (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		username     TEXT NOT NULL UNIQUE COLLATE NOCASE,
		display      TEXT NOT NULL,
		pw_hash      BLOB NOT NULL,
		pw_salt      BLOB NOT NULL,
		pw_params    INTEGER NOT NULL,
		flags        INTEGER NOT NULL DEFAULT 0,
		status       TEXT NOT NULL DEFAULT '',
		status_until INTEGER NOT NULL DEFAULT 0,
		avatar       INTEGER REFERENCES blobs(id),
		created      INTEGER NOT NULL,
		last_seen    INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE devices (
		key       BLOB PRIMARY KEY,
		account   INTEGER NOT NULL REFERENCES accounts(id),
		name      TEXT NOT NULL,
		created   INTEGER NOT NULL,
		last_seen INTEGER NOT NULL
	) WITHOUT ROWID;
	CREATE INDEX devices_account ON devices(account);
	`,
	// 3: conversations and who is a member of each (see convs.odin). The two
	// accounts of a direct message, the last message of a conversation, and what
	// a member has read and wants to be notified about are for later.
	`
	CREATE TABLE convs (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		kind       INTEGER NOT NULL,
		flags      INTEGER NOT NULL DEFAULT 0,
		name       TEXT,
		topic      TEXT NOT NULL DEFAULT '',
		a          INTEGER,
		b          INTEGER,
		position   INTEGER NOT NULL DEFAULT 0,
		created    INTEGER NOT NULL,
		created_by INTEGER,
		last_msg   INTEGER NOT NULL DEFAULT 0
	);
	CREATE UNIQUE INDEX convs_name ON convs(name COLLATE NOCASE) WHERE kind = 0;
	CREATE UNIQUE INDEX convs_dm   ON convs(a, b) WHERE kind = 1;

	CREATE TABLE members (
		conv    INTEGER NOT NULL REFERENCES convs(id),
		account INTEGER NOT NULL REFERENCES accounts(id),
		read_id INTEGER NOT NULL DEFAULT 0,
		notify  INTEGER NOT NULL DEFAULT 0,
		joined  INTEGER NOT NULL,
		PRIMARY KEY (conv, account)
	) WITHOUT ROWID;
	CREATE INDEX members_account ON members(account);
	`,
	// 4: messages (see messages.odin). The flags, thread, edit time and replies
	// of a message are for later. The index on `blob` finds the messages that
	// show a picture, to know who may fetch it.
	`
	CREATE TABLE messages (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		conv        INTEGER NOT NULL REFERENCES convs(id),
		sender      INTEGER NOT NULL REFERENCES accounts(id),
		time        INTEGER NOT NULL,
		kind        INTEGER NOT NULL,
		flags       INTEGER NOT NULL DEFAULT 0,
		thread_root INTEGER NOT NULL DEFAULT 0,
		text        TEXT,
		blob        INTEGER REFERENCES blobs(id),
		edited      INTEGER NOT NULL DEFAULT 0,
		reply_count INTEGER NOT NULL DEFAULT 0,
		last_reply  INTEGER NOT NULL DEFAULT 0,
		nonce       INTEGER
	);
	CREATE INDEX messages_conv   ON messages(conv, id);
	CREATE INDEX messages_thread ON messages(thread_root, id) WHERE thread_root != 0;
	CREATE UNIQUE INDEX messages_nonce ON messages(sender, nonce) WHERE nonce IS NOT NULL;
	CREATE INDEX messages_blob   ON messages(blob) WHERE blob IS NOT NULL;
	`,
	// 5: the people in an account's buddy list (see buddies.odin), and the size
	// of a file that a message offers (see files.odin), whose name is the
	// message's text.
	`
	CREATE TABLE buddies (
		account INTEGER NOT NULL REFERENCES accounts(id),
		buddy   INTEGER NOT NULL REFERENCES accounts(id),
		PRIMARY KEY (account, buddy)
	) WITHOUT ROWID;

	ALTER TABLE messages ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0;
	`,
	// 6: the messages pinned in each conversation, by whom and when (see
	// messages.odin). The message's own flags record this as well.
	`
	CREATE TABLE pins (
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		by      INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (conv, message)
	) WITHOUT ROWID;
	`,
	// 7: who each message mentions (see mentions.odin), to count the mentions
	// for them.
	`
	CREATE TABLE mentions (
		account INTEGER NOT NULL,
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		PRIMARY KEY (account, conv, message)
	) WITHOUT ROWID;
	CREATE INDEX mentions_message ON mentions(message);
	`,
	// 8: who reacted to which message with which emoji (see reactions.odin).
	`
	CREATE TABLE reactions (
		message INTEGER NOT NULL REFERENCES messages(id),
		emoji   TEXT NOT NULL,
		account INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (message, emoji, account)
	) WITHOUT ROWID;
	`,
	// 9: each account's settings, which its clients store there (see
	// profiles.odin).
	`
	CREATE TABLE settings (
		account INTEGER NOT NULL REFERENCES accounts(id),
		key     TEXT NOT NULL,
		value   BLOB NOT NULL,
		PRIMARY KEY (account, key)
	) WITHOUT ROWID;
	`,
	// 10: roles and which accounts have them (see roles.odin), including the role
	// that everyone has. Also, a channel's name is free to use again once the
	// channel is archived.
	`
	CREATE TABLE roles (
		id       INTEGER PRIMARY KEY AUTOINCREMENT,
		name     TEXT NOT NULL UNIQUE COLLATE NOCASE,
		perms    INTEGER NOT NULL,
		position INTEGER NOT NULL DEFAULT 0
	);
	INSERT INTO roles (id, name, perms) VALUES (1, 'everyone', 0);

	CREATE TABLE account_roles (
		account INTEGER NOT NULL REFERENCES accounts(id),
		role    INTEGER NOT NULL REFERENCES roles(id),
		PRIMARY KEY (account, role)
	) WITHOUT ROWID;

	DROP INDEX convs_name;
	CREATE UNIQUE INDEX convs_name ON convs(name COLLATE NOCASE) WHERE kind = 0 AND flags & 4 = 0;
	`,
	// 11: an ordered index of the messages that still have a picture, so that
	// pictures can be purged (see retention.odin) without reading every message.
	`
	CREATE INDEX messages_pictures ON messages(id) WHERE blob IS NOT NULL;
	`,
	// 12: whether an account chose to be online, away, busy or offline (see
	// activity.odin).
	`
	ALTER TABLE accounts ADD COLUMN activity INTEGER NOT NULL DEFAULT 0;
	`,
	// 13: where a forwarded message came from: who wrote the original, in which
	// conversation, and when (see messages.odin, polish 12).
	`
	ALTER TABLE messages ADD COLUMN fwd_sender INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE messages ADD COLUMN fwd_conv INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE messages ADD COLUMN fwd_time INTEGER NOT NULL DEFAULT 0;
	`,
	// 14: an index of the words in text messages, for searching them (see
	// search.odin, polish 13). It stores no text of its own (`content`), and the
	// triggers update it when messages are posted, edited, deleted or purged. It
	// only covers text messages, because other kinds keep other things in `text`.
	`
	CREATE VIRTUAL TABLE messages_fts USING fts5(
		text,
		content = 'messages',
		content_rowid = 'id',
		tokenize = 'unicode61 remove_diacritics 2'
	);
	CREATE TRIGGER messages_fts_add AFTER INSERT ON messages
	WHEN new.kind = 0 AND new.text IS NOT NULL BEGIN
		INSERT INTO messages_fts (rowid, text) VALUES (new.id, new.text);
	END;
	CREATE TRIGGER messages_fts_remove AFTER DELETE ON messages
	WHEN old.kind = 0 AND old.text IS NOT NULL BEGIN
		INSERT INTO messages_fts (messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
	END;
	CREATE TRIGGER messages_fts_change AFTER UPDATE OF text ON messages
	WHEN old.kind = 0 BEGIN
		INSERT INTO messages_fts (messages_fts, rowid, text)
			SELECT 'delete', old.id, old.text WHERE old.text IS NOT NULL;
		INSERT INTO messages_fts (rowid, text)
			SELECT new.id, new.text WHERE new.text IS NOT NULL;
	END;
	INSERT INTO messages_fts (rowid, text)
		SELECT id, text FROM messages WHERE kind = 0 AND text IS NOT NULL;
	`,
	// 15: the files attached to messages (see attachments.odin), in the order
	// they were attached. A blob of NULL means that retention has removed the
	// file. They are removed together with their message, both when it is purged
	// and when it is deleted (see msg_delete). Initially everyone may attach
	// files.
	`
	CREATE TABLE attachments (
		msg  INTEGER NOT NULL,
		idx  INTEGER NOT NULL,
		blob INTEGER,
		name TEXT NOT NULL,
		size INTEGER NOT NULL,
		PRIMARY KEY (msg, idx)
	) WITHOUT ROWID;
	CREATE INDEX attachments_blob ON attachments (blob) WHERE blob IS NOT NULL;
	CREATE TRIGGER attachments_purged AFTER DELETE ON messages BEGIN
		DELETE FROM attachments WHERE msg = old.id;
	END;
	UPDATE roles SET perms = perms | 512 WHERE id = 1;
	`,
	// 16: an index of the names of the files attached to messages, for searching
	// them together with the words of messages (see search.odin). It has one row
	// per message containing the names of its files, which is created and deleted
	// together with the message.
	`
	CREATE VIRTUAL TABLE files_fts USING fts5(
		names,
		tokenize = 'unicode61 remove_diacritics 2'
	);
	INSERT INTO files_fts (rowid, names)
		SELECT msg, group_concat(name, ' ') FROM attachments GROUP BY msg;
	CREATE TRIGGER files_fts_purged AFTER DELETE ON messages BEGIN
		DELETE FROM files_fts WHERE rowid = old.id;
	END;
	`,
	// 17: a role's colour, which is used to show the names of its members (see
	// roles.odin). Its position, which has existed since step 10, says which role
	// ranks above another.
	`
	ALTER TABLE roles ADD COLUMN color INTEGER NOT NULL DEFAULT 0;
	`,
	// 18: an account's email address in lower case, or '' for none (see
	// email.odin and accounts.odin). An address can only belong to one account at
	// a time, and deleted accounts (flag 8) have none.
	`
	ALTER TABLE accounts ADD COLUMN email TEXT NOT NULL DEFAULT '';
	CREATE UNIQUE INDEX accounts_email ON accounts(email) WHERE email != '';
	`,
	// 19: invite codes (see invites.odin), and which account registered with which
	// code (see register.odin).
	`
	CREATE TABLE invites (
		code     TEXT PRIMARY KEY,
		creator  INTEGER NOT NULL,
		created  INTEGER NOT NULL,
		max_uses INTEGER NOT NULL,
		uses     INTEGER NOT NULL DEFAULT 0,
		expires  INTEGER NOT NULL DEFAULT 0,
		revoked  INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX invites_creator ON invites(creator);
	CREATE TABLE invite_uses (
		code    TEXT NOT NULL,
		account INTEGER NOT NULL,
		used    INTEGER NOT NULL
	);
	CREATE INDEX invite_uses_account ON invite_uses(account);
	`,
	// 20: what is needed to verify an account's email address (see verify.odin):
	// the code that its mail has to contain, and when the account is deleted if
	// it hasn't been verified (0 means never). These are set while the account is
	// Unverified (flag 16).
	`
	ALTER TABLE accounts ADD COLUMN verify_code TEXT NOT NULL DEFAULT '';
	ALTER TABLE accounts ADD COLUMN verify_expires INTEGER NOT NULL DEFAULT 0;
	`,
	// 21: a role's flags (see proto.Role_Flags), such as whether it can be
	// mentioned.
	`
	ALTER TABLE roles ADD COLUMN flags INTEGER NOT NULL DEFAULT 0;
	`,
	// 22: a picture in a message becomes an attachment. Each picture message
	// (kind 1) becomes a text message with no text, which carries its picture as
	// its only file (flag 16), named after the time it was posted. The picture's
	// blob becomes a file blob (kind 4). Deleted messages stay deleted.
	// `messages.blob` is unused from here on and always NULL. The column stays
	// because SQLite can't drop a column that references another table. Its index
	// stays as well, which saves deleting a blob from having to look through every
	// message for that reference.
	`
	INSERT INTO attachments (msg, idx, blob, name, size)
		SELECT m.id, 0, m.blob,
			'pasted-image-' || strftime('%Y%m%d-%H%M%S', m.time / 1000, 'unixepoch') || '.jpg',
			coalesce(b.size, 0)
		FROM messages m LEFT JOIN blobs b ON b.id = m.blob
		WHERE m.kind = 1 AND m.flags & 1 = 0;
	INSERT INTO files_fts (rowid, names)
		SELECT m.id, a.name FROM messages m JOIN attachments a ON a.msg = m.id
		WHERE m.kind = 1;
	INSERT INTO messages_fts (rowid, text)
		SELECT id, '' FROM messages WHERE kind = 1 AND flags & 1 = 0;
	UPDATE messages SET
		kind  = 0,
		text  = CASE WHEN flags & 1 = 0 THEN '' END,
		flags = CASE WHEN flags & 1 = 0 THEN flags | 16 ELSE flags END,
		blob  = NULL
	WHERE kind = 1;
	UPDATE blobs SET kind = 4 WHERE kind = 1;
	DROP INDEX messages_pictures;
	`,
	// 23: how a device described itself when it logged in (see proto.MAX_AGENT),
	// for the account's list of devices.
	`
	ALTER TABLE devices ADD COLUMN agent TEXT NOT NULL DEFAULT '';
	`,
	// 24: the newest message at the time an account was last emailed what it
	// missed (see digest.odin).
	`
	ALTER TABLE accounts ADD COLUMN digest_upto INTEGER NOT NULL DEFAULT 0;
	`,
	// 25: Web Push subscriptions (push_subs.odin). Each belongs to a device, and is
	// deleted along with it.
	`
	CREATE TABLE push_subs (
		id       INTEGER PRIMARY KEY,
		device   BLOB NOT NULL REFERENCES devices(key) ON DELETE CASCADE,
		account  INTEGER NOT NULL REFERENCES accounts(id),
		endpoint TEXT NOT NULL UNIQUE,
		p256dh   BLOB NOT NULL,
		auth     BLOB NOT NULL,
		created  INTEGER NOT NULL
	);
	CREATE INDEX push_subs_account ON push_subs(account);
	CREATE INDEX push_subs_device ON push_subs(device);
	`,
}

// The version a database has once it has been through every step.
SCHEMA_VERSION :: len(MIGRATIONS)

// db_migrate takes a database that is at `version` through the steps it hasn't
// been through yet.
@(require_results)
db_migrate :: proc(db: ^DB, version: int, path: string) -> bool {
	if version > SCHEMA_VERSION {
		log.errorf(
			"%s was created by a newer yap-server (schema version %d, this server only knows up to %d)",
			path,
			version,
			SCHEMA_VERSION,
		)
		return false
	}
	for step in version ..< SCHEMA_VERSION {
		if !db_exec(db, "BEGIN") {
			return false
		}
		if !db_exec(db, MIGRATIONS[step]) ||
		   !db_exec(db, fmt.tprintf("PRAGMA user_version = %d", step + 1)) ||
		   !db_exec(db, "COMMIT") {
			db_exec(db, "ROLLBACK")
			log.errorf("%s: schema step %d failed", path, step + 1)
			return false
		}
		if version > 0 {
			log.infof("%s: schema upgraded to version %d", path, step + 1)
		}
	}
	if version == 0 {
		log.infof("created %s", path)
	}
	return true
}
