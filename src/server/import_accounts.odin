package server

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:avatar"
import "common:proto"
import "mattermost"
import "sqlite"

// The importer's writing of accounts (docs/design/mattermost-import.md, 7c):
// the accounts of the plan with their roles and pictures, passwords for those
// who can log in, tombstones for authors that are gone, and the file that the
// passwords are written to. Everything is written in the database's one
// transaction, which the caller commits when all the steps are done (or rolls
// back, and then import_undo removes the files that were written).

// Importer is what the writing steps work on.
Importer :: struct {
	scan:        ^mattermost.Scan,
	db:          ^DB,
	accounts:    ^Accounts,
	convs:       ^Convs,
	blobs:       ^Blob_Store,
	// The parameters that passwords are hashed with (tests use the cheapest).
	hash_params: int,
	// How many threads hash passwords.
	threads:     int,
	// Mattermost's username -> the account that it is in yap: the members, the
	// bots, those who left, and the tombstones of authors who are gone.
	ids:         map[string]proto.Account_Id,
	// The passwords that were made, for the file that the admin hands them out
	// from.
	passwords:   [dynamic]Generated,
	// The files this import has written, which are removed if it fails.
	written:     [dynamic]string,
	// The channel each of the scan's channels became, in the same order, and
	// the DM or group for each of the scan's direct channels by their key
	// (mattermost.direct_key). Messages are written to these (7e).
	channels:    []^Conv,
	directs:     map[string]^Conv,
	// Where the passwords were written, once they were.
	csv:         string,
	// What the steps keep their strings in; freed by importer_destroy.
	arena:       virtual.Arena,
}

Generated :: struct {
	username: string,
	email:    string,
	password: string,
}

importer_init :: proc(im: ^Importer) {
	_ = virtual.arena_init_growing(&im.arena)
	a := virtual.arena_allocator(&im.arena)
	im.ids = make(map[string]proto.Account_Id, a)
	im.directs = make(map[string]^Conv, a)
	im.passwords.allocator = a
	im.written.allocator = a
	if im.hash_params == 0 && im.threads == 0 {
		im.hash_params = HASH_PARAMS_NOW
	}
	if im.threads == 0 {
		im.threads = clamp(os.get_processor_core_count(), 1, 8)
	}
}

importer_destroy :: proc(im: ^Importer) {
	for g in im.passwords {
		// The passwords are in the arena: clear them before it goes.
		crypto.zero_explicit(raw_data(g.password), len(g.password))
	}
	virtual.arena_destroy(&im.arena)
	im^ = {}
}

// import_precheck says whether a database can be imported into (D5): one that a
// server has never been used with. A server that has been started once has
// made the first admin and the home channel, which doesn't count; anything more,
// whether accounts, messages or files, does. The first admin is removed, since
// the import makes the accounts, and the server would otherwise take the
// database for one that has them. Call it before the accounts are loaded. The
// message is allocated with the temp allocator (or is a constant).
import_precheck :: proc(db: ^DB) -> (err: string) {
	count :: proc(db: ^DB, sql: string) -> i64 {
		n, rc := db_pragma_int(db, sql)
		return n if rc == sqlite.OK else -1
	}
	accounts := count(db, "SELECT count(*) FROM accounts")
	flags := count(db, "SELECT coalesce(max(flags), 0) FROM accounts")
	used := [?]struct {
		sql, what: string,
	} {
		{"SELECT count(*) FROM devices", "devices that people have logged in with"},
		{"SELECT count(*) FROM messages", "messages"},
		{"SELECT count(*) FROM blobs", "stored files"},
		{"SELECT count(*) FROM convs WHERE kind != 0 OR created_by IS NOT NULL", "conversations"},
		{"SELECT count(*) FROM roles", "roles"},
		{"SELECT count(*) FROM invites", "invites"},
		{"SELECT count(*) FROM bans", "bans"},
	}
	for u in used {
		n := count(db, u.sql)
		// A new database has the one role, for everyone.
		limit: i64 = 1 if u.what == "roles" else 0
		if n < 0 {
			return "could not read the database"
		}
		if n > limit {
			return fmt.tprintf(
				"the database already has %s: an import needs one that a server has never been used with (move yap.db away, or use a new data folder)",
				u.what,
			)
		}
	}
	switch {
	case accounts < 0:
		return "could not read the database"
	case accounts == 0:
		return ""
	case accounts == 1 && flags == i64(transmute(u8)proto.Account_Flags{.Owner, .Must_Change}):
		// The account that the first start made. Its password was shown in the
		// log once and has never been changed.
		ok := db_exec(
			db,
			"DELETE FROM members WHERE account IN (SELECT id FROM accounts); DELETE FROM account_roles; DELETE FROM settings; DELETE FROM accounts",
		)
		if !ok {
			return "could not remove the account that the server made when it was first started"
		}
		return ""
	}
	return(
		"the database already has accounts: an import needs one that a server has never been used with (move yap.db away, or use a new data folder)" \
	)
}

// A task for the threads that hash passwords: the passwords to hash, and the
// next one to take.
@(private = "file")
Hash_Task :: struct {
	texts:   []string,
	secrets: []Secret,
	params:  int,
	next:    int, // atomic
	done:    int, // atomic
	failed:  bool, // atomic
}

@(private = "file")
hash_thread :: proc(data: rawptr) {
	t := (^Hash_Task)(data)
	for {
		i := sync.atomic_add(&t.next, 1)
		if i >= len(t.texts) {
			return
		}
		p := password_of(t.texts[i])
		secret, ok := secret_make(&p, t.params)
		crypto.zero_explicit(&p, size_of(p))
		if !ok {
			sync.atomic_store(&t.failed, true)
		}
		t.secrets[i] = secret
		sync.atomic_add(&t.done, 1)
	}
}

// hash_passwords hashes all the passwords on several threads, printing
// progress. It returns false if one could not be hashed.
@(private = "file")
hash_passwords :: proc(im: ^Importer, texts: []string) -> (secrets: []Secret, ok: bool) {
	secrets = make([]Secret, len(texts), context.temp_allocator)
	task := Hash_Task {
		texts   = texts,
		secrets = secrets,
		params  = im.hash_params,
	}
	progress := progress_start("hashing passwords")
	workers := make([]^thread.Thread, min(im.threads, max(len(texts), 1)), context.temp_allocator)
	for &w in workers {
		w = thread.create_and_start_with_data(&task, hash_thread, context)
	}
	for {
		done := sync.atomic_load(&task.done)
		progress_update(&progress, i64(done), i64(len(texts)))
		if done >= len(texts) {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	for w in workers {
		thread.join(w)
		thread.destroy(w)
	}
	progress.done = i64(len(texts))
	progress_finish(&progress)
	return secrets, !sync.atomic_load(&task.failed)
}

// import_accounts makes the accounts of the plan. It writes in the open
// transaction and returns false, with a message printed, if anything fails.
import_accounts :: proc(im: ^Importer) -> bool {
	s := im.scan
	plan := &s.plan
	a := virtual.arena_allocator(&im.arena)
	all := proto.Permissions{}
	for p in proto.Permission {
		all += {p}
	}

	// The role of those who administer: everything.
	admin_role: proto.Role_Id
	for acc in plan.accounts {
		if acc.admin {
			role := role_create(im.accounts, "Admin", all, 0, {})
			if role == nil {
				log.error("could not make the Admin role")
				return false
			}
			admin_role = role.id
			break
		}
	}

	// Passwords for everyone who can log in: members who aren't deactivated.
	// Bots have tokens and the others can't log in.
	wanted := make([dynamic]int, 0, len(plan.accounts), context.temp_allocator)
	for acc, i in plan.accounts {
		if !acc.bot && !acc.disabled && !acc.author_only {
			append(&wanted, i)
		}
	}
	texts := make([]string, len(wanted), context.temp_allocator)
	for &t in texts {
		buf := new([GENERATED_PASSWORD_SIZE]u8, a)
		t = generated_password(buf)
	}
	secrets, hashed := hash_passwords(im, texts)
	if !hashed {
		log.error("could not hash the passwords")
		return false
	}

	progress := progress_start("making accounts")
	made := 0
	secret_of := make(map[int]int, context.temp_allocator) // plan index -> wanted index
	for w, i in wanted {
		secret_of[w] = i
	}
	for acc, i in plan.accounts {
		flags: proto.Account_Flags
		secret: Secret
		if k, has := secret_of[i]; has {
			secret = secrets[k]
			flags += {.Must_Change}
		}
		if acc.owner {
			flags += {.Owner}
		}
		if acc.disabled {
			flags += {.Disabled}
		}
		if acc.bot {
			flags += {.Bot}
		}
		made_acc := account_add(im.accounts, acc.name, acc.display, secret, flags)
		if made_acc == nil {
			log.errorf("could not make the account %s", acc.name)
			return false
		}
		if acc.email != "" && !account_set_email(im.accounts, made_acc, acc.email) {
			log.errorf("could not set the email of %s", acc.name)
			return false
		}
		if acc.admin && !account_roles_set(im.accounts, made_acc, {admin_role}) {
			log.errorf("could not give %s the Admin role", acc.name)
			return false
		}
		im.ids[strings.clone(acc.mm_name, a)] = made_acc.id
		if k, has := secret_of[i]; has {
			append(&im.passwords, Generated{acc.name, acc.email, texts[k]})
		}
		made += 1
		progress_update(&progress, i64(made), i64(len(plan.accounts) + len(s.authors_gone)))
	}

	// An author who is gone has no account to be shown as, only a tombstone,
	// which is what an account that is deleted becomes (account_delete.odin).
	for name, i in s.authors_gone {
		acc := account_add(im.accounts, fmt.tprintf("gone%d", i), proto.DELETED_NAME, {}, {})
		if acc == nil || !account_erase_rows(im.db, acc.id) {
			log.errorf("could not make a deleted account for %s", name)
			return false
		}
		im.ids[strings.clone(name, a)] = acc.id
		made += 1
		progress_update(&progress, i64(made), i64(len(plan.accounts) + len(s.authors_gone)))
	}
	progress.done = i64(made)
	progress_finish(&progress)

	return import_avatars(im)
}

// import_avatars gives the accounts their pictures.
@(private = "file")
import_avatars :: proc(im: ^Importer) -> bool {
	s := im.scan
	paths := make(map[string]string, context.temp_allocator) // mm username -> file in data/
	for u in s.users {
		if u.profile_image != "" {
			paths[u.username] = u.profile_image
		}
	}
	for b in s.bots {
		if b.profile_image != "" {
			paths[b.username] = b.profile_image
		}
	}
	progress := progress_start("profile pictures")
	count := 0
	for acc in s.plan.accounts {
		image, has := paths[acc.mm_name]
		if !has {
			continue
		}
		count += 1
		progress_update(&progress, i64(count), i64(len(paths)))
		if !import_avatar(im, acc.mm_name, image) {
			mattermost.note(s, .Avatar_Failed, acc.name, virtual.arena_allocator(&s.arena))
		}
	}
	progress.done = i64(count)
	progress_finish(&progress)
	return true
}

// import_avatar makes one account's picture from a file of the export, as the
// client makes a picture that its user chooses. It returns false if the file
// can't be used (but not if it isn't there, which the scan reported); the
// account then has none.
@(private = "file")
import_avatar :: proc(im: ^Importer, mm_name, image: string) -> bool {
	path, _ := filepath.join({im.scan.dir, mattermost.DATA_DIR, image}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		// Not there: the scan has said so already (Profile_Image_Missing).
		return !os.exists(path)
	}
	jpeg, side, ok := avatar.from_bytes(data, context.temp_allocator)
	if !ok {
		return false
	}
	sum := blob_hash(jpeg)
	file := blob_path(im.blobs, sum, virtual.arena_allocator(&im.arena))
	existed := os.exists(file)
	blob, stored := blob_put(im.blobs, .Avatar, jpeg, side, side)
	if !stored {
		return false
	}
	if !existed && os.exists(file) {
		append(&im.written, file)
	}
	acc := account_by_id(im.accounts, im.ids[mm_name])
	return acc != nil && account_set_avatar(im.accounts, acc, blob)
}

// import_write_passwords writes the passwords that were made to a file, one
// line for each account: username, email and password, with a header. The
// file is for the admin to hand them out from, and holds every password until
// the people change them, so only its owner can read it. It is made new:
// one that exists is not written over.
import_write_passwords :: proc(im: ^Importer, path: string) -> (err: string) {
	file, open_err := os.open(path, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if open_err != nil {
		return fmt.tprintf("could not make %s (it must not exist already): %v", path, open_err)
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "username,email,password\n")
	for g in im.passwords {
		strings.write_string(&b, g.username)
		strings.write_byte(&b, ',')
		strings.write_string(&b, g.email)
		strings.write_byte(&b, ',')
		strings.write_string(&b, g.password)
		strings.write_byte(&b, '\n')
	}
	_, write_err := os.write(file, transmute([]u8)strings.to_string(b))
	os.close(file)
	if write_err != nil {
		os.remove(path)
		return fmt.tprintf("could not write %s: %v", path, write_err)
	}
	im.csv = strings.clone(path, virtual.arena_allocator(&im.arena))
	return ""
}

// import_undo is what a failed import does: it rolls the database back and
// removes the files that it wrote, which the rollback doesn't take with it.
import_undo :: proc(im: ^Importer) {
	db_rollback(im.db)
	for path in im.written {
		os.remove(path)
	}
	if im.csv != "" {
		os.remove(im.csv)
	}
}
