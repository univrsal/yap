package server

import "core:fmt"
import "core:log"

// The database's schema: a baseline that a new database is created with, and
// the steps that changed it since.
//
// A database remembers which version of the schema it has (in SQLite's
// user_version). Opening a database runs the steps it hasn't seen yet, each in
// its own transaction. This way a server that is newer than its database brings
// the database up to date, and a server that stops halfway picks up where it
// left off.
//
// A step that has been released must never be changed, because a database that
// already went through it wouldn't see the change. Anything that needs changing
// gets a new step at the end. The baseline is the schema as of
// BASELINE_VERSION, when the steps before it were squashed; it must not be
// changed either, except to fold in steps when they are squashed again.
//
// A database from a newer server, with steps this server doesn't know, is
// refused instead of guessed at. So is one from before the baseline, apart
// from version 28 (see UPGRADE_28).
//
// Times are Unix milliseconds. Ids are AUTOINCREMENT, so that the id of a row
// that was deleted is never given to another row.

// The version of the baseline.
BASELINE_VERSION :: 29

// The messages (see messages.odin), on their own because UPGRADE_28 builds the
// table again. A message with files has them in `attachments`, and one that
// offers a file has its size in `file_size` and its name in `text` (see
// files.odin). A forwarded message says where it came from: who wrote the
// original, in which conversation, and when.
@(private = "file")
MESSAGES_TABLE :: `
	CREATE TABLE messages (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		conv        INTEGER NOT NULL REFERENCES convs(id),
		sender      INTEGER NOT NULL REFERENCES accounts(id),
		time        INTEGER NOT NULL,
		kind        INTEGER NOT NULL,
		flags       INTEGER NOT NULL DEFAULT 0,
		thread_root INTEGER NOT NULL DEFAULT 0,
		text        TEXT,
		edited      INTEGER NOT NULL DEFAULT 0,
		reply_count INTEGER NOT NULL DEFAULT 0,
		last_reply  INTEGER NOT NULL DEFAULT 0,
		nonce       INTEGER,
		file_size   INTEGER NOT NULL DEFAULT 0,
		fwd_sender  INTEGER NOT NULL DEFAULT 0,
		fwd_conv    INTEGER NOT NULL DEFAULT 0,
		fwd_time    INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX messages_conv   ON messages(conv, id);
	CREATE INDEX messages_thread ON messages(thread_root, id) WHERE thread_root != 0;
	CREATE UNIQUE INDEX messages_nonce ON messages(sender, nonce) WHERE nonce IS NOT NULL;
`

// What keeps the search indexes (messages_fts, files_fts) and the attachments
// in step with the messages. The words of text messages are indexed when they
// are posted, edited, deleted or purged; only text messages, because other
// kinds keep other things in `text`. A message's files and the index of their
// names go when the message is purged.
@(private = "file")
MESSAGES_TRIGGERS :: `
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
	CREATE TRIGGER attachments_purged AFTER DELETE ON messages BEGIN
		DELETE FROM attachments WHERE msg = old.id;
	END;
	CREATE TRIGGER files_fts_purged AFTER DELETE ON messages BEGIN
		DELETE FROM files_fts WHERE rowid = old.id;
	END;
`

@(private = "file")
BASELINE ::
	`
	-- The database's own metadata, and the blobs (see blobs.odin).
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

	-- Accounts (see auth.odin and accounts.odin). An account's activity is
	-- whether it chose to be online, away, busy or offline (activity.odin), and
	-- activity_at and status_at when it last chose that and set its status, so
	-- that clients connected to several servers can keep the newest on all of
	-- them (proto.self_times). Its email address is in lower case, or '' for
	-- none, and can only belong to one account at a time; deleted accounts
	-- (flag 8) have none (mail/mail.odin). verify_code and verify_expires are what
	-- verifying that address takes (verify.odin): the code its mail has to
	-- contain, and when the account is deleted if it hasn't been verified (0
	-- means never); they are set while the account is Unverified (flag 16).
	-- digest_upto is the newest message at the time the account was last
	-- emailed what it missed (digest.odin).
	CREATE TABLE accounts (
		id             INTEGER PRIMARY KEY AUTOINCREMENT,
		username       TEXT NOT NULL UNIQUE COLLATE NOCASE,
		display        TEXT NOT NULL,
		pw_hash        BLOB NOT NULL,
		pw_salt        BLOB NOT NULL,
		pw_params      INTEGER NOT NULL,
		flags          INTEGER NOT NULL DEFAULT 0,
		status         TEXT NOT NULL DEFAULT '',
		status_until   INTEGER NOT NULL DEFAULT 0,
		avatar         INTEGER REFERENCES blobs(id),
		created        INTEGER NOT NULL,
		last_seen      INTEGER NOT NULL DEFAULT 0,
		activity       INTEGER NOT NULL DEFAULT 0,
		email          TEXT NOT NULL DEFAULT '',
		verify_code    TEXT NOT NULL DEFAULT '',
		verify_expires INTEGER NOT NULL DEFAULT 0,
		digest_upto    INTEGER NOT NULL DEFAULT 0,
		activity_at    INTEGER NOT NULL DEFAULT 0,
		status_at      INTEGER NOT NULL DEFAULT 0
	);
	CREATE UNIQUE INDEX accounts_email ON accounts(email) WHERE email != '';

	-- The devices logged in to an account, with how each described itself when
	-- it logged in (see proto.MAX_AGENT).
	CREATE TABLE devices (
		key       BLOB PRIMARY KEY,
		account   INTEGER NOT NULL REFERENCES accounts(id),
		name      TEXT NOT NULL,
		created   INTEGER NOT NULL,
		last_seen INTEGER NOT NULL,
		agent     TEXT NOT NULL DEFAULT ''
	) WITHOUT ROWID;
	CREATE INDEX devices_account ON devices(account);

	-- Conversations and who is a member of each (see convs.odin). A channel's
	-- name is free to use again once the channel is archived (flag 4).
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
	CREATE UNIQUE INDEX convs_dm   ON convs(a, b) WHERE kind = 1;
	CREATE UNIQUE INDEX convs_name ON convs(name COLLATE NOCASE) WHERE kind = 0 AND flags & 4 = 0;

	CREATE TABLE members (
		conv    INTEGER NOT NULL REFERENCES convs(id),
		account INTEGER NOT NULL REFERENCES accounts(id),
		read_id INTEGER NOT NULL DEFAULT 0,
		notify  INTEGER NOT NULL DEFAULT 0,
		joined  INTEGER NOT NULL,
		PRIMARY KEY (conv, account)
	) WITHOUT ROWID;
	CREATE INDEX members_account ON members(account);
` +
	MESSAGES_TABLE +
	`
	-- The people in an account's buddy list (see buddies.odin).
	CREATE TABLE buddies (
		account INTEGER NOT NULL REFERENCES accounts(id),
		buddy   INTEGER NOT NULL REFERENCES accounts(id),
		PRIMARY KEY (account, buddy)
	) WITHOUT ROWID;

	-- The messages pinned in each conversation, by whom and when (see
	-- messages.odin). The message's own flags record this as well.
	CREATE TABLE pins (
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		by      INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (conv, message)
	) WITHOUT ROWID;

	-- Who each message mentions (see mentions.odin), to count the mentions for
	-- them.
	CREATE TABLE mentions (
		account INTEGER NOT NULL,
		conv    INTEGER NOT NULL,
		message INTEGER NOT NULL REFERENCES messages(id),
		PRIMARY KEY (account, conv, message)
	) WITHOUT ROWID;
	CREATE INDEX mentions_message ON mentions(message);

	-- Who reacted to which message with which emoji (see reactions.odin).
	CREATE TABLE reactions (
		message INTEGER NOT NULL REFERENCES messages(id),
		emoji   TEXT NOT NULL,
		account INTEGER NOT NULL,
		time    INTEGER NOT NULL,
		PRIMARY KEY (message, emoji, account)
	) WITHOUT ROWID;

	-- Each account's settings, which its clients store there (see
	-- profiles.odin).
	CREATE TABLE settings (
		account INTEGER NOT NULL REFERENCES accounts(id),
		key     TEXT NOT NULL,
		value   BLOB NOT NULL,
		PRIMARY KEY (account, key)
	) WITHOUT ROWID;

	-- Roles and which accounts have them (see roles.odin), including the role
	-- that everyone has, which may attach files (512). A role's position says
	-- which role ranks above another, its colour is used to show the names of
	-- its members, and its flags are proto.Role_Flags, such as whether it can
	-- be mentioned.
	CREATE TABLE roles (
		id       INTEGER PRIMARY KEY AUTOINCREMENT,
		name     TEXT NOT NULL UNIQUE COLLATE NOCASE,
		perms    INTEGER NOT NULL,
		position INTEGER NOT NULL DEFAULT 0,
		color    INTEGER NOT NULL DEFAULT 0,
		flags    INTEGER NOT NULL DEFAULT 0
	);
	INSERT INTO roles (id, name, perms) VALUES (1, 'everyone', 512);

	CREATE TABLE account_roles (
		account INTEGER NOT NULL REFERENCES accounts(id),
		role    INTEGER NOT NULL REFERENCES roles(id),
		PRIMARY KEY (account, role)
	) WITHOUT ROWID;

	-- An index of the words in text messages, for searching them (see
	-- search.odin). It stores no text of its own (content), and
	-- MESSAGES_TRIGGERS keeps it up to date.
	CREATE VIRTUAL TABLE messages_fts USING fts5(
		text,
		content = 'messages',
		content_rowid = 'id',
		tokenize = 'unicode61 remove_diacritics 2'
	);

	-- The files attached to messages (see attachments.odin), in the order they
	-- were attached. A blob of NULL means that retention has removed the file.
	-- They are removed together with their message, both when it is purged
	-- (MESSAGES_TRIGGERS) and when it is deleted (see msg_delete).
	CREATE TABLE attachments (
		msg  INTEGER NOT NULL,
		idx  INTEGER NOT NULL,
		blob INTEGER,
		name TEXT NOT NULL,
		size INTEGER NOT NULL,
		PRIMARY KEY (msg, idx)
	) WITHOUT ROWID;
	CREATE INDEX attachments_blob ON attachments (blob) WHERE blob IS NOT NULL;

	-- An index of the names of the files attached to messages, for searching
	-- them together with the words of messages (see search.odin). It has one
	-- row per message containing the names of its files, which is created and
	-- deleted together with the message.
	CREATE VIRTUAL TABLE files_fts USING fts5(
		names,
		tokenize = 'unicode61 remove_diacritics 2'
	);

	-- Invite codes (see invites.odin), and which account registered with which
	-- code (see register.odin).
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

	-- Web Push subscriptions (push_subs.odin). Each belongs to a device, and is
	-- deleted along with it.
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

	-- What each role may do in each channel (convs.odin, conv_rights).
	CREATE TABLE conv_rights (
		conv   INTEGER NOT NULL REFERENCES convs(id),
		role   INTEGER NOT NULL REFERENCES roles(id),
		rights INTEGER NOT NULL,
		PRIMARY KEY (conv, role)
	) WITHOUT ROWID;
` +
	MESSAGES_TRIGGERS

// UPGRADE_28 brings a database from the last of the squashed steps (28) to the
// baseline. The only difference is `messages.blob`, which pictures used before
// they became attachments (step 22) and which has been NULL since, and its
// index. SQLite can't drop a column that references another table, so the
// table is built again: the old one is set aside, the rows are copied with
// their ids, and the id counter is kept, so that ids of rows deleted before
// aren't given out again. Foreign keys are off meanwhile (see db_migrate), and
// legacy_alter_table keeps the other tables' references pointing at
// `messages` when the old table is renamed.
//
// It can go once no database at version 28 is left.
@(private = "file")
UPGRADE_28 ::
	`
	PRAGMA legacy_alter_table = ON;
	ALTER TABLE messages RENAME TO messages_old;
	DROP INDEX messages_conv;
	DROP INDEX messages_thread;
	DROP INDEX messages_nonce;
	DROP INDEX messages_blob;
` +
	MESSAGES_TABLE +
	`
	INSERT INTO messages (id, conv, sender, time, kind, flags, thread_root, text, edited,
			reply_count, last_reply, nonce, file_size, fwd_sender, fwd_conv, fwd_time)
		SELECT id, conv, sender, time, kind, flags, thread_root, text, edited,
			reply_count, last_reply, nonce, file_size, fwd_sender, fwd_conv, fwd_time
		FROM messages_old;
	DELETE FROM sqlite_sequence WHERE name = 'messages';
	INSERT INTO sqlite_sequence (name, seq)
		SELECT 'messages', seq FROM sqlite_sequence WHERE name = 'messages_old';
	DROP TABLE messages_old;
	PRAGMA legacy_alter_table = OFF;
` +
	MESSAGES_TRIGGERS

// The steps since the baseline, the first of which takes a database to
// BASELINE_VERSION + 1.
@(private = "file", rodata)
MIGRATIONS := [?]string {
	// 30: bans (proto/moderation.odin). A banned account is also Disabled.
	// `email` is the account's address when it was banned, in lower case or
	// '' for none, which can't be used to register while the ban lasts. The
	// index on messages' senders is for removing one account's messages.
	`
	CREATE TABLE bans (
		account INTEGER PRIMARY KEY REFERENCES accounts(id),
		by      INTEGER NOT NULL REFERENCES accounts(id),
		time    INTEGER NOT NULL,
		reason  TEXT NOT NULL DEFAULT '',
		email   TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX bans_email ON bans(email) WHERE email != '';
	CREATE INDEX messages_sender ON messages(sender, id);
	`,
	// 31: speaking and video in a voice room became rights of their own
	// (proto.Conv_Right.Speak 128, Video 256). Whoever could join a room could
	// do both there, so they still can.
	`
	UPDATE conv_rights SET rights = rights | 384 WHERE rights & 32 != 0;
	`,
	// 32: bookmarks (proto/bookmarks.odin): the messages each account marked
	// to come back to, and when. A message that is purged takes its
	// bookmarks with it.
	`
	CREATE TABLE bookmarks (
		account INTEGER NOT NULL REFERENCES accounts(id),
		message INTEGER NOT NULL REFERENCES messages(id),
		time    INTEGER NOT NULL,
		PRIMARY KEY (account, message)
	) WITHOUT ROWID;
	CREATE INDEX bookmarks_message ON bookmarks(message);
	CREATE TRIGGER bookmarks_purged AFTER DELETE ON messages BEGIN
		DELETE FROM bookmarks WHERE message = old.id;
	END;
	`,
}

// The version a database has once it has been through every step.
SCHEMA_VERSION :: BASELINE_VERSION + len(MIGRATIONS)

// db_migrate brings a database that is at `version` up to SCHEMA_VERSION: a
// new one (version 0) is created with the baseline, and the steps it hasn't
// been through yet are run.
@(require_results)
db_migrate :: proc(db: ^DB, version: int, path: string) -> bool {
	version := version
	switch {
	case version > SCHEMA_VERSION:
		log.errorf(
			"%s was created by a newer yap-server (schema version %d, this server only knows up to %d)",
			path,
			version,
			SCHEMA_VERSION,
		)
		return false
	case version == 0:
		if !schema_step(db, BASELINE, BASELINE_VERSION) {
			log.errorf("%s: creating the schema failed", path)
			return false
		}
		log.infof("created %s", path)
		version = BASELINE_VERSION
	case version == 28:
		// Rebuilding a table needs foreign keys off, and they can only be
		// switched outside a transaction.
		db_exec(db, "PRAGMA foreign_keys = OFF")
		ok := schema_step(db, UPGRADE_28, BASELINE_VERSION)
		db_exec(db, "PRAGMA foreign_keys = ON")
		if !ok {
			log.errorf("%s: schema upgrade to version %d failed", path, BASELINE_VERSION)
			return false
		}
		log.infof("%s: schema upgraded to version %d", path, BASELINE_VERSION)
		version = BASELINE_VERSION
	case version < BASELINE_VERSION:
		log.errorf(
			"%s has schema version %d, from before version %d: upgrade it with a yap-server from before then first (up to version 28), or start with a new database",
			path,
			version,
			BASELINE_VERSION,
		)
		return false
	}
	for step in version ..< SCHEMA_VERSION {
		if !schema_step(db, MIGRATIONS[step - BASELINE_VERSION], step + 1) {
			log.errorf("%s: schema step %d failed", path, step + 1)
			return false
		}
		log.infof("%s: schema upgraded to version %d", path, step + 1)
	}
	return true
}

// schema_step runs `sql` and sets the database's version to `to`, all in one
// transaction.
@(private = "file")
schema_step :: proc(db: ^DB, sql: string, to: int) -> bool {
	if !db_exec(db, "BEGIN") {
		return false
	}
	if !db_exec(db, sql) ||
	   !db_exec(db, fmt.tprintf("PRAGMA user_version = %d", to)) ||
	   !db_exec(db, "COMMIT") {
		db_exec(db, "ROLLBACK")
		return false
	}
	return true
}
