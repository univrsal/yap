package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:proto"
import "mattermost"

// The importer's accounts (import_accounts.odin), from the sample export of
// tools/mattermost.
IMPORT_SAMPLE :: #directory + "../../tools/mattermost/sample"

// Import_Test is an empty database with what an import works on.
Import_Test :: struct {
	db:       DB,
	accounts: Accounts,
	convs:    Convs,
	blobs:    Blob_Store,
	dir:      string,
	scan:     ^mattermost.Scan,
	im:       Importer,
}

it_open :: proc(t: ^testing.T, it: ^Import_Test, export: string, team := "acme") -> bool {
	it.dir = strings.clone(test_dir(t))
	testing.expect(t, db_open(&it.db, DB_MEMORY))
	testing.expect_value(t, import_precheck(&it.db), "")
	testing.expect(t, accounts_load(&it.accounts, &it.db))
	testing.expect(t, convs_load(&it.convs, &it.db, []string{DEFAULT_CHANNEL_NAME}, &it.accounts))
	testing.expect(t, blob_store_open(&it.blobs, &it.db, file_in(it.dir, "blobs")))
	err: string
	it.scan, err = mattermost.scan({dir = export, team = team})
	testing.expect_value(t, err, "")
	if it.scan == nil {
		return false
	}
	testing.expect_value(t, mattermost.build_plan(it.scan, ""), "")
	it.im = {
		scan        = it.scan,
		db          = &it.db,
		accounts    = &it.accounts,
		convs       = &it.convs,
		blobs       = &it.blobs,
		hash_params = HASH_PARAMS_TEST,
		threads     = 2,
	}
	importer_init(&it.im)
	return true
}

it_close :: proc(it: ^Import_Test) {
	importer_destroy(&it.im)
	if it.scan != nil {
		mattermost.scan_destroy(it.scan)
	}
	blob_store_close(&it.blobs)
	convs_destroy(&it.convs)
	accounts_destroy(&it.accounts)
	db_close(&it.db)
	remove_tree(it.dir)
	delete(it.dir)
}

it_count :: proc(it: ^Import_Test, sql: string) -> i64 {
	n, _ := db_pragma_int(&it.db, sql)
	return n
}

@(test)
test_import_accounts :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))
	db_commit(&it.db)

	a := &it.accounts
	// Seven members and three bots.
	testing.expect_value(t, len(a.by_id), 10)
	for mm_name in ([]string {
			"admin",
			"alice",
			"bob",
			"carol",
			"dave",
			"frank",
			"gus",
			"buildbot",
			"calls",
			"playbooks",
		}) {
		testing.expectf(t, mm_name in it.im.ids, "no account for %s", mm_name)
	}
	testing.expect(t, "erin" not_in it.im.ids) // in the other team

	admin := account_find(a, "admin")
	alice := account_find(a, "alice")
	bob := account_find(a, "bob")
	dave := account_find(a, "dave")
	bot := account_find(a, "buildbot")
	testing.expect(t, admin != nil && alice != nil && bob != nil && dave != nil && bot != nil)
	if admin == nil || alice == nil || bob == nil || dave == nil || bot == nil {
		return
	}
	testing.expect_value(t, admin.flags, proto.Account_Flags{.Owner, .Must_Change})
	testing.expect_value(t, bob.flags, proto.Account_Flags{.Must_Change})
	testing.expect_value(t, dave.flags, proto.Account_Flags{.Disabled})
	testing.expect_value(t, bot.flags, proto.Account_Flags{.Bot})
	testing.expect_value(t, alice.display, "Alice Archer")
	testing.expect_value(t, alice.email, "alice@example.invalid")
	testing.expect_value(t, bob.display, "Bobby")

	// The Admin role has every permission, and is given to the system admin
	// and the team's admin, but not to anyone else.
	role := role_by_name(a, "Admin")
	testing.expect(t, role != nil)
	if role != nil {
		for p in proto.Permission {
			testing.expectf(t, p in role.perms, "Admin lacks %v", p)
		}
		testing.expect_value(t, len(admin.roles), 1)
		testing.expect_value(t, len(alice.roles), 1)
		testing.expect_value(t, len(bob.roles), 0)
		testing.expect_value(t, alice.roles[0], role.id)
	}

	// Passwords were made for the six who can log in, and each one works with
	// the account's own hash. Nobody else has one.
	testing.expect_value(t, len(it.im.passwords), 6)
	for g in it.im.passwords {
		acc := account_find(a, g.username)
		testing.expect(t, acc != nil)
		if acc == nil {
			continue
		}
		secret, ok := account_secret(a, acc)
		testing.expect(t, ok)
		p := password_of(g.password)
		testing.expectf(
			t,
			secret_matches(&p, &secret),
			"the password of %s doesn't match",
			g.username,
		)
		testing.expect_value(t, len(g.password), GENERATED_PASSWORD_SIZE)
		testing.expect(t, .Must_Change in acc.flags)
	}
	for g in it.im.passwords {
		testing.expect(t, g.username != "dave" && g.username != "buildbot")
	}

	// Pictures: only some accounts have one, each a JPEG that yap accepts.
	with_picture := 0
	for _, acc in a.by_id {
		if acc.avatar == 0 {
			continue
		}
		with_picture += 1
		blob, found := blob_get(&it.blobs, acc.avatar)
		testing.expect(t, found)
		testing.expect_value(t, blob.kind, Blob_Kind.Avatar)
		testing.expect(t, blob.size <= proto.MAX_AVATAR_SIZE)
		testing.expect(
			t,
			blob.width <= proto.MAX_AVATAR_SIDE && blob.width == blob.height && blob.width > 0,
		)
		data, read := blob_read(&it.blobs, acc.avatar)
		testing.expect(t, read)
		testing.expect(t, len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8)
		delete(data)
	}
	testing.expect_value(t, with_picture, 3)
	testing.expect_value(t, it.scan.issues[.Avatar_Failed].count, 0)

	// All of it is in the database, not only in memory.
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM accounts"), 10)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM accounts WHERE avatar IS NOT NULL"),
		3,
	)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM account_roles"), 2)
}

@(test)
test_import_passwords_file :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))

	path := file_in(it.dir, "passwords.csv")
	testing.expect_value(t, import_write_passwords(&it.im, path), "")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	testing.expect_value(t, len(lines), 7)
	testing.expect_value(t, lines[0], "username,email,password")
	for line in lines[1:] {
		fields := strings.split(line, ",", context.temp_allocator)
		testing.expect_value(t, len(fields), 3)
		acc := account_find(&it.accounts, fields[0])
		testing.expect(t, acc != nil)
		if acc != nil {
			testing.expect_value(t, fields[1], acc.email)
		}
		testing.expect_value(t, len(fields[2]), GENERATED_PASSWORD_SIZE)
	}
	// Only its owner can read it.
	when ODIN_OS != .Windows {
		info, stat_err := os.stat(path, context.temp_allocator)
		testing.expect(t, stat_err == nil)
		others := os.Permissions {
			.Read_Group,
			.Write_Group,
			.Execute_Group,
			.Read_Other,
			.Write_Other,
			.Execute_Other,
		}
		testing.expect(t, .Read_User in info.mode && .Write_User in info.mode)
		testing.expect_value(t, info.mode & others, os.Permissions{})
	}
	// A file that exists is never written over.
	testing.expect(t, import_write_passwords(&it.im, path) != "")
}

@(test)
test_import_undo :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))
	path := file_in(it.dir, "passwords.csv")
	testing.expect_value(t, import_write_passwords(&it.im, path), "")
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM accounts"), 10)
	testing.expect(t, len(it.im.written) > 0)
	files := it.im.written[:]

	import_undo(&it.im)
	// The database is as it was, and so are the files.
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM accounts"), 0)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM blobs"), 0)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM roles"), 1)
	for f in files {
		testing.expectf(t, !os.exists(f), "%s is still there", f)
	}
	testing.expect(t, !os.exists(path))
}

@(test)
test_import_precheck :: proc(t: ^testing.T) {
	// Something to import into: a database in a file, so that it can be opened again.
	dir := test_dir(t)
	defer remove_tree(dir)
	path := file_in(dir, DB_FILE)
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		testing.expect_value(t, import_precheck(&db), "") // new
	}
	// What the server's first start leaves: the first admin, its password never changed.
	{
		db: DB
		a: Accounts
		testing.expect(t, db_open(&db, path))
		testing.expect(t, accounts_load(&a, &db))
		secret, _ := secret_make(&Password{}, HASH_PARAMS_TEST)
		acc := account_add(&a, "admin", "Admin", secret, {.Owner, .Must_Change})
		testing.expect(t, acc != nil)
		db_commit(&db)
		accounts_destroy(&a)
		db_close(&db)
	}
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		testing.expect_value(t, import_precheck(&db), "")
		n, _ := db_pragma_int(&db, "SELECT count(*) FROM accounts")
		testing.expect_value(t, n, 0)
		db_rollback(&db)
	}
	// An account that someone has used: it has been given a new password.
	{
		db: DB
		a: Accounts
		testing.expect(t, db_open(&db, path))
		testing.expect(t, accounts_load(&a, &db))
		secret, _ := secret_make(&Password{}, HASH_PARAMS_TEST)
		testing.expect(t, account_add(&a, "admin", "Admin", secret, {.Owner}) != nil)
		db_commit(&db)
		accounts_destroy(&a)
		db_close(&db)
	}
	{
		db: DB
		testing.expect(t, db_open(&db, path))
		defer db_close(&db)
		err := import_precheck(&db)
		testing.expect(t, strings.contains(err, "already has accounts"))
	}
	// So does one with anything else in it, such as a stored file.
	{
		db: DB
		testing.expect(t, db_open(&db, file_in(dir, "other.db")))
		defer db_close(&db)
		testing.expect(
			t,
			db_exec(
				&db,
				"INSERT INTO blobs (sha256, size, kind, width, height, created) VALUES (zeroblob(32), 1, 4, 0, 0, 1)",
			),
		)
		err := import_precheck(&db)
		testing.expect(t, strings.contains(err, "stored files"))
	}
}

// export_of writes an export with `lines` in a new folder.
export_of :: proc(t: ^testing.T, lines: ..string) -> string {
	dir := strings.clone(test_dir(t))
	text := strings.join(lines, "\n", context.temp_allocator)
	testing.expect(t, os.write_entire_file(file_in(dir, mattermost.IMPORT_FILE), text) == nil)
	return dir
}

@(test)
test_import_gone_and_guests :: proc(t: ^testing.T) {
	version := `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
	dir := export_of(
		t,
		version,
		`{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`,
		`{"type":"channel","channel":{"team":"acme","name":"town-square","display_name":"Town Square","type":"O"}}`,
		`{"type":"user","user":{"username":"root","email":"r@example.invalid","roles":"system_user system_admin","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`,
		`{"type":"user","user":{"username":"visitor","email":"v@example.invalid","roles":"system_guest","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`,
		`{"type":"post","post":{"team":"acme","channel":"town-square","user":"deleted-person","message":"hi","create_at":1}}`,
	)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))

	// The guest is made, disabled, with no password.
	visitor := account_find(&it.accounts, "visitor")
	testing.expect(t, visitor != nil)
	if visitor != nil {
		testing.expect_value(t, visitor.flags, proto.Account_Flags{.Disabled})
	}
	testing.expect_value(t, it.scan.issues[.Guest_Disabled].count, 1)
	testing.expect_value(t, len(it.im.passwords), 1)
	testing.expect_value(t, it.im.passwords[0].username, "root")

	// The author who is gone is a tombstone, which the messages can name.
	id, has := it.im.ids["deleted-person"]
	testing.expect(t, has)
	gone := account_by_id(&it.accounts, id)
	testing.expect(t, gone != nil)
	n, _ := db_pragma_int(&it.db, "SELECT flags FROM accounts WHERE username LIKE 'deleted#%'")
	testing.expect_value(t, n, i64(transmute(u8)proto.Account_Flags{.Deleted}))
	count, _ := db_pragma_int(
		&it.db,
		"SELECT count(*) FROM accounts WHERE display = 'Deleted user'",
	)
	testing.expect_value(t, count, 1)
}

@(test)
test_import_missing_picture :: proc(t: ^testing.T) {
	version := `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
	dir := export_of(
		t,
		version,
		`{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`,
		`{"type":"user","user":{"username":"root","roles":"system_admin","profile_image":"users/x/profile.png","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`,
		`{"type":"user","user":{"username":"broken","roles":"system_user","profile_image":"users/y/profile.png","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`,
	)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	// One picture is a file that isn't a picture, and the other isn't there.
	testing.expect(t, os.make_directory_all(file_in(dir, "data/users/y")) == nil)
	testing.expect(
		t,
		os.write_entire_file(file_in(dir, "data/users/y/profile.png"), "not a picture") == nil,
	)
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))
	// The accounts are made without them, and it says so.
	testing.expect_value(t, len(it.accounts.by_id), 2)
	for _, acc in it.accounts.by_id {
		testing.expect_value(t, acc.avatar, 0)
	}
	testing.expect_value(t, it.scan.issues[.Avatar_Failed].count, 1) // the file that isn't a picture
	testing.expect_value(t, it.scan.issues[.Profile_Image_Missing].count, 1)
	_ = filepath.base
}
