package server

import "core:fmt"
import "core:log"

/*
The database's schema, as the steps that made it.

A database remembers how many of these steps it has been through
(SQLite's user_version). Opening one runs the steps it hasn't seen, each
in a transaction of its own, so a server that's newer than its database
brings it up to date, and one that stops halfway picks up where it left
off.

A step that has been released is never changed: a database that already
went through it wouldn't see the change. What needs changing gets a new
step at the end.

A database from a newer server, with steps this one doesn't know, is
refused rather than guessed at.

Times are Unix milliseconds. Ids are AUTOINCREMENT, so that the id of a
row that's gone is never given to another.
*/

@(private = "file", rodata)
MIGRATIONS := [?]string {
	// 1: the database's notes about itself, and the blobs (blobs.odin).
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
	// 2: accounts and the devices logged in to them (auth.odin). An
	// account's status and avatar are for later.
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
	// 3: conversations and who is a member of each (convs.odin). The two
	// accounts of a direct message, a conversation's last message, and
	// what a member has read and wants to hear of are for later.
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
	// 4: messages (messages.odin). A message's flags, thread, edit time
	// and replies are for later. The index on `blob` finds the messages
	// that show a picture, to know who may fetch it.
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
	// 5: the people an account keeps in its buddy list (buddies.odin),
	// and the size of a file a message offers (files.odin), its name
	// being the message's text.
	`
	CREATE TABLE buddies (
		account INTEGER NOT NULL REFERENCES accounts(id),
		buddy   INTEGER NOT NULL REFERENCES accounts(id),
		PRIMARY KEY (account, buddy)
	) WITHOUT ROWID;

	ALTER TABLE messages ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0;
	`,
	// 6: the messages pinned in each conversation, by whom and when
	// (messages.odin); a message's own flags say so too.
	`
	CREATE TABLE pins (
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		by      INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (conv, message)
	) WITHOUT ROWID;
	`,
	// 7: who each message mentions (mentions.odin), to count it for them.
	`
	CREATE TABLE mentions (
		account INTEGER NOT NULL,
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		PRIMARY KEY (account, conv, message)
	) WITHOUT ROWID;
	CREATE INDEX mentions_message ON mentions(message);
	`,
	// 8: who reacted to what with which emoji (reactions.odin).
	`
	CREATE TABLE reactions (
		message INTEGER NOT NULL REFERENCES messages(id),
		emoji   TEXT NOT NULL,
		account INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (message, emoji, account)
	) WITHOUT ROWID;
	`,
	// 9: each account's settings, as its clients keep them there
	// (profiles.odin).
	`
	CREATE TABLE settings (
		account INTEGER NOT NULL REFERENCES accounts(id),
		key     TEXT NOT NULL,
		value   BLOB NOT NULL,
		PRIMARY KEY (account, key)
	) WITHOUT ROWID;
	`,
	// 10: roles, and which accounts have them (roles.odin), with the
	// role everyone has; and a channel's name is free again once it's
	// archived.
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
	// 11: the messages that still have a picture, in order, for purging
	// pictures (retention.odin) without reading every message.
	`
	CREATE INDEX messages_pictures ON messages(id) WHERE blob IS NOT NULL;
	`,
	// 12: whether an account chose to be online, away, busy or offline
	// (activity.odin).
	`
	ALTER TABLE accounts ADD COLUMN activity INTEGER NOT NULL DEFAULT 0;
	`,
	// 13: where a forwarded message came from: who wrote the original,
	// in which conversation, when (messages.odin, polish 12).
	`
	ALTER TABLE messages ADD COLUMN fwd_sender INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE messages ADD COLUMN fwd_conv INTEGER NOT NULL DEFAULT 0;
	ALTER TABLE messages ADD COLUMN fwd_time INTEGER NOT NULL DEFAULT 0;
	`,
	// 14: an index of the words of text messages, for searching them
	// (search.odin, polish 13). It keeps no text of its own (`content`):
	// the triggers tell it what's posted, edited, deleted and purged.
	// Only text messages: other kinds keep other things in `text`.
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
	// 15: the files messages carry (attachments.odin), in the order they
	// were attached; a blob of NULL is one retention has removed. They go
	// with their message, when it's purged as when it's deleted
	// (msg_delete). Everyone may attach files to start with.
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
	// 16: an index of the names of messages' files, for searching them
	// with the words of messages (search.odin): one row a message, its
	// files' names, written with it and gone with it.
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
}

// The version a database is at once it has been through every step.
SCHEMA_VERSION :: len(MIGRATIONS)

// db_migrate takes a database at `version` through the steps it hasn't
// seen.
@(require_results)
db_migrate :: proc(db: ^DB, version: int, path: string) -> bool {
	if version > SCHEMA_VERSION {
		log.errorf(
			"%s was made by a newer yap-server (schema %d, this one knows %d)",
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
			log.errorf("%s: step %d of the schema failed", path, step + 1)
			return false
		}
		if version > 0 {
			log.infof("%s: schema brought to version %d", path, step + 1)
		}
	}
	if version == 0 {
		log.infof("created %s", path)
	}
	return true
}
