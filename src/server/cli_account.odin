package server

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "common:proto"

// `yap-server account ...` manages accounts from the command line. It is meant
// for whoever runs the server and has no client at hand, or can no longer log in
// with one (for example because the owner forgot their password).
//
//	yap-server account list             [config.json]
//	yap-server account add <username>    [config.json]
//	yap-server account passwd <username> [config.json]
//	yap-server account owner <username>  [config.json]
//	yap-server account verify <username> [config.json]
//	yap-server account role <username> <role>    [config.json]
//	yap-server account unrole <username> <role>  [config.json]
//	yap-server account delete <username> [config.json]
//	yap-server account bots <count> <password> [config.json]
//	yap-server role list                [config.json]
//
// `add` and `passwd` generate a password and print it. Like any password that
// somebody else chose, it is only good for logging in and choosing a new one.
// `passwd` also logs out all of the account's devices.
// `owner` makes the account the server's owner, replacing the previous owner.
// `verify` marks an account as verified even if its email address (see
// verify.odin) hasn't been verified.
// `role` and `unrole` give an account a role or take it away, and `role list`
// lists the roles and what they allow. This helps on a server that nobody can
// manage anymore.
// `delete` permanently deletes an account (see account_delete.odin). Its
// messages are kept and shown under "Deleted user". The owner can't be deleted.
//
// These commands work on the database directly, which only one process can use
// at a time, so they can't run while the server is running.

ACCOUNT_USAGE :: `usage: yap-server account list [config.json]
       yap-server account add <username> [config.json]
       yap-server account passwd <username> [config.json]
       yap-server account owner <username> [config.json]
       yap-server account verify <username> [config.json]
       yap-server account role <username> <role> [config.json]
       yap-server account unrole <username> <role> [config.json]
       yap-server account delete <username> [config.json]
       yap-server account bots <count> <password> [config.json]
       yap-server role list [config.json]`

// account_bots implements `account bots <count> <password>`. It creates the
// accounts bot1 to bot<count>, all with the given password and no forced
// password change on first login. They are meant for the stress test
// (src/stress) to log in as. Accounts that already exist are left alone, so the
// command can be run again to create more. The password is hashed only once and
// the same hash (including its salt) is shared by all of them, since they are
// meant for testing and not for real users.
@(private = "file")
account_bots :: proc(args: []string) -> int {
	if len(args) < 2 || len(args) > 3 {
		fmt.eprintln(ACCOUNT_USAGE)
		return 2
	}
	count, count_ok := strconv.parse_int(args[0])
	if !count_ok || count < 1 || count > 100_000 {
		fmt.eprintfln("%q isn't a valid number of bots (1 to 100000)", args[0])
		return 2
	}
	if !proto.account_password_ok(args[1]) {
		fmt.eprintfln(
			"the password must be %d to %d bytes long",
			proto.MIN_ACCOUNT_PASSWORD,
			proto.MAX_ACCOUNT_PASSWORD,
		)
		return 2
	}
	config := args[2] if len(args) == 3 else DEFAULT_CONFIG_FILE
	if !os.exists(config) {
		fmt.eprintfln(
			"%s: config file not found (start the server once to create it, or pass the path to its config)",
			config,
		)
		return 2
	}
	settings, config_ok := load_config(config)
	if !config_ok {
		return 2
	}
	db: DB
	if !db_open(&db, settings.db_path) {
		return 1
	}
	defer db_close(&db)
	a: Accounts
	if !accounts_load(&a, &db) {
		return 1
	}
	defer accounts_destroy(&a)

	password := password_of(args[1])
	defer crypto.zero_explicit(&password, size_of(password))
	secret, hashed := secret_make(&password, HASH_PARAMS_NOW)
	if !hashed {
		log.error("could not hash the password")
		return 1
	}
	made := 0
	for i in 1 ..= count {
		username := fmt.tprintf("bot%d", i)
		if account_find(&a, username) != nil {
			continue
		}
		if account_add(&a, username, username, secret, {}) == nil {
			return 1
		}
		made += 1
	}
	db_commit(&db)
	fmt.printfln("created %d bot accounts (%d already existed)", made, count - made)
	return 0
}

// run_account_command runs `yap-server account <args...>` and returns
// the process's exit code.
run_account_command :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln(ACCOUNT_USAGE)
		return 2
	}
	command := args[0]
	if command == "bots" {
		return account_bots(args[1:])
	}
	// The number of names the command takes: a username, and for role commands
	// also a role name.
	names := 0
	switch command {
	case "list", "roles":
	case "add", "passwd", "owner", "verify", "delete":
		names = 1
	case "role", "unrole":
		names = 2
	case:
		fmt.eprintln(ACCOUNT_USAGE)
		return 2
	}
	rest := args[1:]
	if len(rest) < names || len(rest) > names + 1 {
		fmt.eprintln(ACCOUNT_USAGE)
		return 2
	}
	raw_name := rest[0] if names > 0 else ""
	role_name := rest[1] if names > 1 else ""
	config := DEFAULT_CONFIG_FILE
	if len(rest) == names + 1 {
		config = rest[len(rest) - 1]
	}

	// The server writes its config on the first run, so the CLI doesn't create one.
	if !os.exists(config) {
		fmt.eprintfln(
			"%s: config file not found (start the server once to create it, or pass the path to its config)",
			config,
		)
		return 2
	}
	settings, config_ok := load_config(config)
	if !config_ok {
		return 2
	}
	db: DB
	if !db_open(&db, settings.db_path) {
		return 1
	}
	defer db_close(&db)
	a: Accounts
	if !accounts_load(&a, &db) {
		return 1
	}
	defer accounts_destroy(&a)

	if command == "list" {
		account_list(&a)
		return 0
	}
	if command == "roles" {
		role_list(&a)
		return 0
	}

	name_buf: [proto.MAX_USERNAME_SIZE]u8
	username, clean := proto.username_clean(raw_name, &name_buf)
	if !clean {
		fmt.eprintfln(
			"%q isn't a valid username: it must be %d to %d characters of a-z 0-9 _ . -",
			raw_name,
			proto.MIN_USERNAME_SIZE,
			proto.MAX_USERNAME_SIZE,
		)
		return 2
	}
	acc := account_find(&a, username)

	switch command {
	case "add":
		if acc != nil {
			fmt.eprintfln("the account %s already exists", username)
			return 1
		}
		text_buf: [GENERATED_PASSWORD_SIZE]u8
		secret, text, hashed := generated_secret(&text_buf)
		if !hashed {
			return 1
		}
		// The first account created becomes the server's owner.
		flags := proto.Account_Flags{.Must_Change}
		if len(a.by_id) == 0 {
			flags += {.Owner}
		}
		if account_add(&a, username, username, secret, flags) == nil {
			return 1
		}
		fmt.printfln(
			"created the account %s%s",
			username,
			" (the server's owner)" if .Owner in flags else "",
		)
		fmt.printfln("password: %s", text)
		fmt.println("the password has to be changed on first login")

	case "passwd":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
			return 1
		}
		if .Bot in acc.flags {
			fmt.eprintfln(
				"%s is a bot, which uses tokens instead of a password (tokens are created in the client)",
				username,
			)
			return 1
		}
		text_buf: [GENERATED_PASSWORD_SIZE]u8
		secret, text, hashed := generated_secret(&text_buf)
		if !hashed || !account_set_password(&a, acc, secret, true) {
			return 1
		}
		devices := 0
		for d in devices_of(&a, acc) {
			if device_unlink(&a, d.key) {
				devices += 1
			}
		}
		fmt.printfln("new password for %s: %s", username, text)
		fmt.printfln(
			"the password has to be changed on first login; logged out %d device(s)",
			devices,
		)

	case "owner":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
			return 1
		}
		if .Bot in acc.flags {
			fmt.eprintfln("%s is a bot, and bots can't own the server", username)
			return 1
		}
		for _, other in a.by_id {
			if other != acc && !account_set_flags(&a, other, other.flags - {.Owner}) {
				return 1
			}
		}
		if !account_set_flags(&a, acc, acc.flags + {.Owner}) {
			return 1
		}
		fmt.printfln("%s is now the server's owner", username)

	case "verify":
		switch {
		case acc == nil:
			fmt.eprintfln("there is no account called %s", username)
			return 1
		case .Unverified not_in acc.flags:
			fmt.printfln("%s is already verified", username)
			return 0
		}
		if !account_set_verify(&a, acc, acc.flags - {.Unverified}, "", 0) {
			return 1
		}
		fmt.printfln("%s is verified", username)

	case "delete":
		switch {
		case acc == nil:
			fmt.eprintfln("there is no account called %s", username)
			return 1
		case .Owner in acc.flags:
			fmt.eprintfln(
				"%s is the server's owner; make another account the owner before deleting it",
				username,
			)
			return 1
		case !account_erase_rows(&db, acc.id):
			return 1
		}
		db_commit(&db)
		fmt.printfln(
			"deleted the account %s; its messages are kept and shown under %q",
			username,
			proto.DELETED_NAME,
		)

	case "role", "unrole":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
			return 1
		}
		r := role_by_name(&a, role_name)
		switch {
		case r == nil:
			fmt.eprintfln("there is no role called %s (see `yap-server role list`)", role_name)
			return 1
		case r.id == proto.EVERYONE_ROLE:
			fmt.eprintln("every account has that role, and it can't be changed")
			return 1
		}
		roles := make([dynamic]proto.Role_Id, context.temp_allocator)
		for id in acc.roles {
			if id != r.id {
				append(&roles, id)
			}
		}
		if command == "role" {
			append(&roles, r.id)
		}
		if !account_roles_set(&a, acc, roles[:]) {
			return 1
		}
		fmt.printfln(
			"%s %s the role %s now",
			username,
			"has" if command == "role" else "doesn't have",
			r.name,
		)
	}
	return 0
}

@(private = "file")
role_list :: proc(a: ^Accounts) {
	fmt.printfln("%-5s %-32s %-8s %s", "id", "role", "accounts", "allows")
	for r in roles_sorted(a) {
		count := 0
		for _, acc in a.by_id {
			if r.id == proto.EVERYONE_ROLE || slice.contains(acc.roles[:], r.id) {
				count += 1
			}
		}
		allows := "nothing more" if r.perms == {} else fmt.tprint(r.perms)
		fmt.printfln("%-5d %-32s %-8d %s", r.id, r.name, count, allows)
	}
}

@(private = "file")
generated_secret :: proc(
	buf: ^[GENERATED_PASSWORD_SIZE]u8,
) -> (
	secret: Secret,
	text: string,
	ok: bool,
) {
	text = generated_password(buf)
	password := password_of(text)
	defer crypto.zero_explicit(&password, size_of(password))
	secret, ok = secret_make(&password, HASH_PARAMS_NOW)
	if !ok {
		log.error("could not hash the password")
	}
	return
}

@(private = "file")
account_list :: proc(a: ^Accounts) {
	if len(a.by_id) == 0 {
		fmt.println(
			"no accounts yet: the server creates one called admin when it starts, or you can use `account add`",
		)
		return
	}
	fmt.printfln(
		"%-5s %-32s %-12s %-7s %-20s %s",
		"id",
		"username",
		"",
		"devices",
		"last here",
		"name",
	)
	// Sorted by id, which is the order the accounts were created in.
	ids, _ := slice.map_keys(a.by_id, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		acc := a.by_id[id]
		role := ""
		switch {
		case .Owner in acc.flags:
			role = "owner"
		case .Deleted in acc.flags:
			role = "deleted"
		case .Disabled in acc.flags:
			role = "disabled"
		case .Bot in acc.flags:
			role = "bot"
		case len(acc.roles) > 0:
			role = a.roles[acc.roles[0]].name if acc.roles[0] in a.roles else ""
		}
		seen := "never"
		if acc.last_seen > 0 {
			at := time.unix(acc.last_seen / 1000, 0)
			y, mon, d := time.date(at)
			h, m, _ := time.clock(at)
			seen = fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mon), d, h, m)
		}
		fmt.printfln(
			"%-5d %-32s %-12s %-7d %-20s %s",
			acc.id,
			acc.username,
			role,
			len(devices_of(a, acc)),
			seen,
			acc.display,
		)
	}
}
