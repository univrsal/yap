package server

import "core:os"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests of `yap-server account ...` and `role list` (cli_account.odin). Each
// command is run against a config and a database in a folder of the test's
// own, and what it did is read back from the database afterwards, since the
// commands print their answers and return an exit code.

@(private = "file")
Cli :: struct {
	dir:      string,
	config:   string,
	db_path:  string,
	settings: Settings,
}

@(private = "file")
cli_rig :: proc(t: ^testing.T) -> (c: Cli) {
	c.dir = test_dir(t)
	c.config = file_in(c.dir, "config.json")
	ok: bool
	c.settings, ok = load_config(c.config)
	testing.expect(t, ok)
	c.db_path = c.settings.db_path
	return
}

@(private = "file")
cli_done :: proc(c: Cli) {
	os.remove_all(c.dir)
}

// run runs `account <args...> <config>` and returns its exit code.
@(private = "file")
run :: proc(c: Cli, args: ..string) -> int {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, ..args)
	append(&list, c.config)
	return run_account_command(list[:])
}

// Opened is the database and the accounts, read back after a command ran.
@(private = "file")
Opened :: struct {
	db: DB,
	a:  Accounts,
}

@(private = "file")
reopen :: proc(t: ^testing.T, c: Cli) -> ^Opened {
	o := new(Opened, context.temp_allocator)
	testing.expect(t, cli_open(&o.db, &o.a, c.db_path))
	return o
}

// secret_of reads an account's stored password hash.
@(private = "file")
secret_of :: proc(o: ^Opened, name: string) -> Secret {
	acc := account_find(&o.a, name)
	secret, _ := account_secret(&o.a, acc)
	return secret
}

@(private = "file")
reclose :: proc(o: ^Opened) {
	cli_close(&o.db, &o.a)
}

// seed makes an account directly in the database.
@(private = "file")
seed :: proc(t: ^testing.T, c: Cli, name: string, flags := proto.Account_Flags{}) {
	o := reopen(t, c)
	defer reclose(o)
	acc := account_add(&o.a, name, name, Secret{}, flags)
	testing.expect(t, acc != nil)
	db_commit(&o.db)
}

@(test)
test_account_usage :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)

	testing.expect_value(t, run_account_command(nil), 2)
	testing.expect_value(t, run(c, "nonsense"), 2)
	testing.expect_value(t, run(c, "add"), 2) // a name is needed
	testing.expect_value(t, run_account_command({"add", "a", "b", "c"}), 2)
	testing.expect_value(t, run(c, "role", "alice"), 2) // and a role
	testing.expect_value(t, run_account_command({"list", "x", "y"}), 2)
	// A config that isn't there is the user's mistake, not a crash.
	testing.expect_value(t, run_account_command({"list", file_in(c.dir, "missing.json")}), 2)
	testing.expect_value(t, run_account_command({"add", "alice", file_in(c.dir, "missing.json")}), 2)
	// The role command only lists.
	testing.expect_value(t, run_role_command(nil), 2)
	testing.expect_value(t, run_role_command({"delete"}), 2)
	testing.expect_value(t, run_role_command({"list", c.config}), 0)
}

@(test)
test_account_add :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)

	testing.expect_value(t, run(c, "add", "alice"), 0)
	testing.expect_value(t, run(c, "add", "Bob"), 0) // as the server stores it
	testing.expect_value(t, run(c, "add", "alice"), 1) // taken
	for bad in ([]string{"", "has space", "UPPER CASE", "x/y"}) {
		testing.expectf(t, run(c, "add", bad) == 2, "%q was accepted", bad)
	}

	o := reopen(t, c)
	defer reclose(o)
	alice := account_find(&o.a, "alice")
	bob := account_find(&o.a, "bob")
	testing.expect(t, alice != nil && bob != nil)
	if alice != nil && bob != nil {
		// The first account is the server's owner; both must choose a new password.
		testing.expect(t, .Owner in alice.flags && .Owner not_in bob.flags)
		testing.expect(t, .Must_Change in alice.flags && .Must_Change in bob.flags)
		// The password that was generated is stored hashed, and not the same for both.
		testing.expect(t, secret_of(o, "alice").hash != secret_of(o, "bob").hash)
		testing.expect(t, secret_of(o, "alice").hash != {})
	}
	testing.expect_value(t, len(o.a.by_id), 2)
}

@(test)
test_account_passwd :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	seed(t, c, "alice")
	seed(t, c, "robot", {.Bot})
	{
		o := reopen(t, c)
		defer reclose(o)
		acc := account_find(&o.a, "alice")
		key: [proto.KEY_SIZE]u8
		key[0] = 1
		testing.expect(t, device_link(&o.a, key, acc, "laptop", "agent") != nil)
		key[0] = 2
		testing.expect(t, device_link(&o.a, key, acc, "phone", "agent") != nil)
		db_commit(&o.db)
	}

	testing.expect_value(t, run(c, "passwd", "nobody"), 1)
	testing.expect_value(t, run(c, "passwd", "robot"), 1) // bots use tokens
	testing.expect_value(t, run(c, "passwd", "alice"), 0)

	o := reopen(t, c)
	defer reclose(o)
	alice := account_find(&o.a, "alice")
	testing.expect(t, .Must_Change in alice.flags)
	testing.expect(t, secret_of(o, "alice").hash != {})
	// A new password logs the devices out, so that whoever had the old one is out.
	testing.expect_value(t, len(devices_of(&o.a, alice)), 0)
}

@(test)
test_account_owner :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	seed(t, c, "alice", {.Owner})
	seed(t, c, "bob")
	seed(t, c, "robot", {.Bot})

	testing.expect_value(t, run(c, "owner", "nobody"), 1)
	testing.expect_value(t, run(c, "owner", "robot"), 1)
	{
		o := reopen(t, c)
		defer reclose(o)
		testing.expect(t, .Owner in account_find(&o.a, "alice").flags, "the owner changed for a bot")
	}
	testing.expect_value(t, run(c, "owner", "bob"), 0)

	// There is one owner, the new one.
	o := reopen(t, c)
	defer reclose(o)
	testing.expect(t, .Owner not_in account_find(&o.a, "alice").flags)
	testing.expect(t, .Owner in account_find(&o.a, "bob").flags)
}

@(test)
test_account_verify :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	seed(t, c, "alice", {.Unverified})
	seed(t, c, "bob")

	testing.expect_value(t, run(c, "verify", "nobody"), 1)
	testing.expect_value(t, run(c, "verify", "bob"), 0) // already is
	testing.expect_value(t, run(c, "verify", "alice"), 0)
	o := reopen(t, c)
	defer reclose(o)
	testing.expect(t, .Unverified not_in account_find(&o.a, "alice").flags)
}

@(test)
test_cli_account_delete :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	seed(t, c, "alice", {.Owner})
	seed(t, c, "bob")

	testing.expect_value(t, run(c, "delete", "nobody"), 1)
	// The owner has to be made someone else first.
	testing.expect_value(t, run(c, "delete", "alice"), 1)
	testing.expect_value(t, run(c, "delete", "bob"), 0)
	o := reopen(t, c)
	defer reclose(o)
	bob := account_find(&o.a, "bob")
	// Gone for log in, and its name is free again.
	testing.expect(t, bob == nil || .Deleted in bob.flags)
	testing.expect(t, .Owner in account_find(&o.a, "alice").flags)
}

@(test)
test_account_ban_and_unban :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)

	// With no owner there is nobody to ban in the name of.
	seed(t, c, "bob")
	testing.expect_value(t, run(c, "ban", "bob", "spam"), 1)
	seed(t, c, "alice", {.Owner})
	seed(t, c, "carol")

	testing.expect_value(t, run(c, "ban", "nobody", "x"), 1)
	testing.expect_value(t, run(c, "ban", "alice", "x"), 1) // the owner can't be
	long := strings.repeat("r", proto.MAX_BAN_REASON + 1, context.temp_allocator)
	testing.expect_value(t, run(c, "ban", "carol", long), 2)
	testing.expect_value(t, run(c, "ban", "carol", "spam\nand more"), 0)

	{
		o := reopen(t, c)
		defer reclose(o)
		carol := account_find(&o.a, "carol")
		ban, banned := ban_of(&o.a, carol.id)
		testing.expect(t, banned)
		testing.expect(t, .Disabled in carol.flags)
		testing.expect(t, !strings.contains(ban.reason, "\n"), "a line break in the reason")
		testing.expect(t, strings.has_prefix(ban.reason, "spam"))
		// Done by the owner.
		testing.expect_value(t, ban.by, account_find(&o.a, "alice").id)
	}

	testing.expect_value(t, run(c, "bans"), 0)
	testing.expect_value(t, run(c, "unban", "nobody"), 1)
	testing.expect_value(t, run(c, "unban", "bob"), 0) // wasn't banned
	testing.expect_value(t, run(c, "unban", "carol"), 0)
	{
		o := reopen(t, c)
		defer reclose(o)
		carol := account_find(&o.a, "carol")
		_, banned := ban_of(&o.a, carol.id)
		testing.expect(t, !banned)
		testing.expect(t, .Disabled not_in carol.flags)
	}
	testing.expect_value(t, run(c, "bans"), 0) // nobody is banned
}

@(test)
test_account_roles :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	seed(t, c, "alice")
	{
		o := reopen(t, c)
		defer reclose(o)
		testing.expect(t, role_create(&o.a, "Helpers", {.Invite}, 0, {}) != nil)
		testing.expect(t, role_create(&o.a, "Mods", {.Ban_Members}, 0, {}) != nil)
		db_commit(&o.db)
	}

	testing.expect_value(t, run(c, "role", "nobody", "helpers"), 1)
	testing.expect_value(t, run(c, "role", "alice", "nothing"), 1)
	testing.expect_value(t, run(c, "role", "alice", "everyone"), 1) // everyone has it
	testing.expect_value(t, run(c, "role", "alice", "helpers"), 0) // (by name, whatever the case)
	testing.expect_value(t, run(c, "role", "alice", "MODS"), 0)
	testing.expect_value(t, run(c, "role", "alice", "mods"), 0) // twice is once
	{
		o := reopen(t, c)
		defer reclose(o)
		alice := account_find(&o.a, "alice")
		testing.expect_value(t, len(alice.roles), 2)
	}
	testing.expect_value(t, run(c, "unrole", "alice", "helpers"), 0)
	testing.expect_value(t, run(c, "unrole", "alice", "helpers"), 0) // not having it is fine
	{
		o := reopen(t, c)
		defer reclose(o)
		alice := account_find(&o.a, "alice")
		testing.expect_value(t, len(alice.roles), 1)
		mods := role_by_name(&o.a, "mods")
		testing.expect(t, mods != nil && alice.roles[0] == mods.id)
	}
	testing.expect_value(t, run(c, "roles"), 0)
	testing.expect_value(t, run(c, "list"), 0)
}

@(test)
test_listing_with_no_accounts :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	testing.expect_value(t, run(c, "list"), 0)
	testing.expect_value(t, run(c, "bans"), 0)
	testing.expect_value(t, run(c, "roles"), 0)
}

@(test)
test_creating_bot_accounts :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	c := cli_rig(t)
	defer cli_done(c)
	run3 :: proc(c: Cli, args: ..string) -> int {
		list := make([dynamic]string, context.temp_allocator)
		append(&list, "bots")
		append(&list, ..args)
		return run_account_command(list[:])
	}

	// A count and a password are needed, and have to make sense.
	testing.expect_value(t, run_account_command({"bots"}), 2)
	testing.expect_value(t, run_account_command({"bots", "5"}), 2)
	testing.expect_value(t, run3(c, "0", "password", c.config), 2)
	testing.expect_value(t, run3(c, "100001", "password", c.config), 2)
	testing.expect_value(t, run3(c, "many", "password", c.config), 2)
	testing.expect_value(t, run3(c, "-3", "password", c.config), 2)
	testing.expect_value(t, run3(c, "3", "short", c.config), 2)
	testing.expect_value(t, run3(c, "3", strings.repeat("p", proto.MAX_ACCOUNT_PASSWORD + 1, context.temp_allocator), c.config), 2)
	testing.expect_value(t, run_account_command({"bots", "3", "password", file_in(c.dir, "missing.json")}), 2)

	testing.expect_value(t, run3(c, "3", "password1", c.config), 0)
	{
		o := reopen(t, c)
		defer reclose(o)
		testing.expect_value(t, len(o.a.by_id), 3)
		for name in ([]string{"bot1", "bot2", "bot3"}) {
			acc := account_find(&o.a, name)
			testing.expectf(t, acc != nil, "%s was not made", name)
			if acc != nil {
				testing.expect(t, .Must_Change not_in acc.flags, "bots must not be made to change their password")
			}
		}
		// They share one hash, as documented.
		testing.expect(t, secret_of(o, "bot1").hash == secret_of(o, "bot3").hash)
	}
	// Running it again with more only makes the new ones.
	testing.expect_value(t, run3(c, "5", "password1", c.config), 0)
	o := reopen(t, c)
	defer reclose(o)
	testing.expect_value(t, len(o.a.by_id), 5)
}

@(test)
test_cli_config_needs_a_config :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)
	_, ok := cli_config(file_in(dir, "missing.json"))
	testing.expect(t, !ok)
	// The command never creates one.
	testing.expect(t, !os.exists(file_in(dir, "missing.json")))
}
