package server

import "core:fmt"
import "core:os"
import "core:testing"

import "common:proto"
import "sqlite"

// Tests of the other commands of yap-server: purge (cli_purge.odin), the
// import's arguments (cli_import.odin), and what email and push say before
// they would reach out to anything (cli_email.odin, cli_push.odin).

// ---- purge ----

@(private = "file")
Purge_Rig :: struct {
	dir:      string,
	config:   string,
	db_path:  string,
	blobs:    string,
	settings: Settings,
}

@(private = "file")
purge_rig :: proc(t: ^testing.T) -> (r: Purge_Rig) {
	r.dir = test_dir(t)
	r.config = file_in(r.dir, "config.json")
	ok: bool
	r.settings, ok = load_config(r.config)
	testing.expect(t, ok)
	r.db_path, r.blobs = r.settings.db_path, r.settings.blobs_dir
	return
}

// seed_messages posts messages in the home channel, a second channel and a DM,
// through a server that uses the rig's database, and stops it again.
@(private = "file")
seed_messages :: proc(t: ^testing.T, r: Purge_Rig) {
	ts: Test_Server
	ts_open(t, &ts, r.db_path)
	defer ts_close(&ts)
	s := &ts.s
	testing.expect(t, blob_store_open(&s.blobs, &s.db, r.blobs))
	defer blob_store_close(&s.blobs)
	admin_acc := ts_account(t, &ts, "admin", "a password", {.Owner})
	bob_acc := ts_account(t, &ts, "bob", "a password")
	testing.expect(t, conv_member_add(&s.convs, conv_by_name(&s.convs, "Gaming"), admin_acc.id))
	admin := logged_in(t, &ts, "admin")
	_ = logged_in(t, &ts, "bob")
	_, dm := dm_open_as(t, &ts, admin, bob_acc.id)
	for i in 0 ..< 3 {
		st, _ := post(t, &ts, admin, s.convs.home.id, "in the lobby", u64(1 + i))
		testing.expect_value(t, st, proto.Status.Ok)
		st, _ = post(t, &ts, admin, conv_id_of(&ts, "Gaming"), "in gaming", u64(10 + i))
		testing.expect_value(t, st, proto.Status.Ok)
	}
	st, _ := post(t, &ts, admin, dm, "a private one", 20)
	testing.expect_value(t, st, proto.Status.Ok)
	db_commit(&s.db)
}

@(private = "file")
conv_id_of :: proc(ts: ^Test_Server, name: string) -> proto.Conv_Id {
	conv := conv_by_name(&ts.s.convs, name)
	return conv.id if conv != nil else 0
}

// messages_in counts the messages left in the rig's database, in all of
// the conversations or one.
@(private = "file")
messages_left :: proc(t: ^testing.T, r: Purge_Rig, conv: proto.Conv_Id = 0) -> i64 {
	ts: Test_Server
	ts_open(t, &ts, r.db_path)
	defer ts_close(&ts)
	sql := "SELECT count(*) FROM messages"
	if conv != 0 {
		sql = fmt_sql(conv)
	}
	n, rc := db_pragma_int(&ts.s.db, sql)
	testing.expect_value(t, rc, sqlite.OK)
	return n
}

@(private = "file")
fmt_sql :: proc(conv: proto.Conv_Id) -> string {
	return fmt.tprintf("SELECT count(*) FROM messages WHERE conv = %d", conv)
}

@(test)
test_purge_arguments :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	r := purge_rig(t)
	defer os.remove_all(r.dir)

	testing.expect_value(t, run_purge_command(nil), 2)
	testing.expect_value(t, run_purge_command({"all"}), 2)
	testing.expect_value(t, run_purge_command({"all", "30d", r.config, "extra"}), 2)
	testing.expect_value(t, run_purge_command({"-y", "files"}), 2)
	// A date that isn't one.
	for bad in ([]string{"yesterday", "2026-13-01", "-3d", "d", "2026-02-30"}) {
		testing.expectf(t, run_purge_command({"all", bad, "-y", r.config}) == 2, "%q was taken for a date", bad)
	}
	// No config.
	testing.expect_value(t, run_purge_command({"all", "30d", "-y", file_in(r.dir, "missing.json")}), 2)
}

@(test)
test_purge_unknown_targets :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	r := purge_rig(t)
	defer os.remove_all(r.dir)
	seed_messages(t, r)
	before := messages_left(t, r)

	for target in ([]string{"nowhere", "#nowhere", "nobody+bob", "admin+bob+nobody", "admin+admin2", "bob+carol"}) {
		testing.expectf(t, run_purge_command({target, "0d", "-y", r.config}) == 1, "%q was purged", target)
	}
	testing.expect_value(t, messages_left(t, r), before)
}

@(test)
test_purge_everything :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	r := purge_rig(t)
	defer os.remove_all(r.dir)
	seed_messages(t, r)
	testing.expect(t, messages_left(t, r) >= 7)

	// Nothing is older than a long time ago.
	testing.expect_value(t, run_purge_command({"all", "2000-01-01", "-y", r.config}), 0)
	testing.expect(t, messages_left(t, r) >= 7)

	testing.expect_value(t, run_purge_command({"all", "0d", "-y", r.config}), 0)
	testing.expect_value(t, messages_left(t, r), 0)
	// With nothing left it still succeeds (it only cleans up).
	testing.expect_value(t, run_purge_command({"all", "0d", "-y", r.config}), 0)
}

@(test)
test_purge_one_conversation :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	r := purge_rig(t)
	defer os.remove_all(r.dir)
	seed_messages(t, r)

	ts: Test_Server
	ts_open(t, &ts, r.db_path)
	home, gaming := ts.s.convs.home.id, conv_id_of(&ts, "Gaming")
	dm: proto.Conv_Id
	for _, conv in ts.s.convs.dms {
		dm = conv.id
	}
	ts_close(&ts)
	lobby_before := messages_left(t, r, home)
	gaming_before := messages_left(t, r, gaming)
	dm_before := messages_left(t, r, dm)
	testing.expect(t, lobby_before >= 3 && gaming_before == 3 && dm_before == 1)

	// A channel by name (with or without the #), leaving the rest alone.
	testing.expect_value(t, run_purge_command({"#Gaming", "0d", "-y", r.config}), 0)
	testing.expect_value(t, messages_left(t, r, gaming), 0)
	testing.expect_value(t, messages_left(t, r, home), lobby_before)
	testing.expect_value(t, messages_left(t, r, dm), dm_before)

	// A DM as the two accounts, in either order.
	testing.expect_value(t, run_purge_command({"bob+admin", "0d", "-y", r.config}), 0)
	testing.expect_value(t, messages_left(t, r, dm), 0)
	testing.expect_value(t, messages_left(t, r, home), lobby_before)

	testing.expect_value(t, run_purge_command({"lobby", "0d", "-y", r.config}), 0)
	testing.expect_value(t, messages_left(t, r, home), 0)
}

// ---- the import's arguments ----

@(test)
test_import_arguments :: proc(t: ^testing.T) {
	a, ok := parse_import_args({"mattermost", "export", "--team", "acme"})
	testing.expect(t, ok)
	testing.expect_value(t, a.folder, "export")
	testing.expect_value(t, a.team, "acme")
	testing.expect_value(t, a.config, DEFAULT_CONFIG_FILE)
	testing.expect(t, !a.dry_run && !a.yes && !a.fetch_icons)
	testing.expect_value(t, a.owner, "")

	// A value in the same argument or the next, flags anywhere, a config last.
	a, ok = parse_import_args(
		{
			"mattermost",
			"--owner=root",
			"export dir",
			"--team=acme",
			"--passwords",
			"pw.csv",
			"--dry-run",
			"-y",
			"--fetch-icons",
			"my.json",
		},
	)
	testing.expect(t, ok)
	testing.expect_value(t, a.folder, "export dir")
	testing.expect_value(t, a.config, "my.json")
	testing.expect_value(t, a.owner, "root")
	testing.expect_value(t, a.passwords, "pw.csv")
	testing.expect(t, a.dry_run && a.yes && a.fetch_icons)
	a, ok = parse_import_args({"mattermost", "x", "--team", "t", "--yes"})
	testing.expect(t, ok && a.yes)
	// A value with an = in it keeps the rest.
	a, ok = parse_import_args({"mattermost", "x", "--team=a=b"})
	testing.expect(t, ok)
	testing.expect_value(t, a.team, "a=b")
}

@(test)
test_import_arguments_that_are_wrong :: proc(t: ^testing.T) {
	bad := [][]string {
		{},
		{"slack", "x", "--team", "t"},
		{"mattermost"},
		{"mattermost", "x"}, // no team
		{"mattermost", "--team", "t"}, // no folder
		{"mattermost", "x", "--team"}, // a value is missing
		{"mattermost", "x", "--team", "t", "--owner"},
		{"mattermost", "x", "--team", "t", "--nonsense"},
		{"mattermost", "x", "--team", "t", "-q"},
		{"mattermost", "x", "y", "z", "--team", "t"}, // too many
	}
	for args, i in bad {
		_, ok := parse_import_args(args)
		testing.expectf(t, !ok, "case %d was accepted: %v", i, args)
	}
	// What is wrong is the user's: a bad export folder is 2, as are bad arguments.
	testing.expect_value(t, run_import_command({"slack"}), 2)
	testing.expect_value(t, run_import_command({"mattermost", "/nonexistent-folder", "--team", "t"}), 2)
}

// ---- email and push, before anything leaves the machine ----

@(test)
test_email_command_checks :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	dir := test_dir(t)
	defer os.remove_all(dir)
	config := file_in(dir, "config.json")
	_, ok := load_config(config)
	testing.expect(t, ok)

	testing.expect_value(t, run_email_command(nil), 2)
	testing.expect_value(t, run_email_command({"send"}), 2)
	testing.expect_value(t, run_email_command({"test", "a@b.org", "c@d.org", config}), 2)
	testing.expect_value(t, run_email_command({"test", file_in(dir, "missing.json")}), 2)
	// No email configured: told so, before anything is tried.
	testing.expect_value(t, run_email_command({"test", config}), 2)
	testing.expect_value(t, run_email_command({"test", "me@example.org", config}), 2)
}

@(test)
test_push_command_checks :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	dir := test_dir(t)
	defer os.remove_all(dir)
	config := file_in(dir, "config.json")
	testing.expect(t, os.write_entire_file(config, `{"push": {"enabled": false}}`) == nil)
	_, ok := load_config(config)
	testing.expect(t, ok)

	testing.expect_value(t, run_push_command(nil), 2)
	testing.expect_value(t, run_push_command({"send"}), 2)
	// Arguments come in 0, 1 (a config), 3 or 4 after "test".
	testing.expect_value(t, run_push_command({"test", "https://x", "y"}), 2)
	testing.expect_value(t, run_push_command({"test", "a", "b", "c", "d", "e"}), 2)
	testing.expect_value(t, run_push_command({"test", file_in(dir, "missing.json")}), 2)
	// Push turned off in the config.
	testing.expect_value(t, run_push_command({"test", config}), 2)
}
