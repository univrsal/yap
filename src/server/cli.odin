package server

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:time"

import "common:proto"

/*
`yap-server account ...`: accounts from the command line, for whoever
runs the server and has no client at hand, or can't get in with one any
more (the owner's password is forgotten, say).

	yap-server account list             [config.json]
	yap-server account add <username>    [config.json]
	yap-server account passwd <username> [config.json]
	yap-server account owner <username>  [config.json]
	yap-server account role <username> <role>    [config.json]
	yap-server account unrole <username> <role>  [config.json]
	yap-server role list                [config.json]

`add` and `passwd` make up a password and print it; like any password
somebody else chose, it's only good for logging in and choosing one's
own. `passwd` also logs the account's devices out. `owner` makes the
account the server's owner, in place of whoever was. `role` and `unrole`
give an account a role or take it away, and `role list` lists the roles
and what they allow: for a server nobody can manage any more.

These work on the database directly, and it's one process's at a time:
they can't run while the server does.
*/

ACCOUNT_USAGE :: `usage: yap-server account list [config.json]
       yap-server account add <username> [config.json]
       yap-server account passwd <username> [config.json]
       yap-server account owner <username> [config.json]
       yap-server account role <username> <role> [config.json]
       yap-server account unrole <username> <role> [config.json]
       yap-server role list [config.json]`

// run_account_command runs `yap-server account <args...>` and returns
// the process's exit code.
run_account_command :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln(ACCOUNT_USAGE)
		return 2
	}
	command := args[0]
	// How many names it takes: a username, and for a role a role's.
	names := 0
	switch command {
	case "list", "roles":
	case "add", "passwd", "owner":
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

	// A server's first run writes its config; this isn't one.
	if !os.exists(config) {
		fmt.eprintfln("%s: no such config (run the server once, or name its config)", config)
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
			"%q can't be a username: %d to %d of a-z 0-9 _ . -",
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
			fmt.eprintfln("there is an account called %s already", username)
			return 1
		}
		text_buf: [GENERATED_PASSWORD_SIZE]u8
		secret, text, hashed := generated_secret(&text_buf)
		if !hashed {
			return 1
		}
		// The first account of all is the server's owner.
		flags := proto.Account_Flags{.Must_Change}
		if len(a.by_id) == 0 {
			flags += {.Owner}
		}
		if account_add(&a, username, username, secret, flags) == nil {
			return 1
		}
		fmt.printfln("made the account %s%s", username, " (the server's owner)" if .Owner in flags else "")
		fmt.printfln("password: %s", text)
		fmt.println("it has to be changed on first login")

	case "passwd":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
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
		fmt.printfln("it has to be changed on first login; %d device(s) logged out", devices)

	case "owner":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
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
		fmt.printfln("%s is the server's owner now", username)

	case "role", "unrole":
		if acc == nil {
			fmt.eprintfln("there is no account called %s", username)
			return 1
		}
		r := role_by_name(&a, role_name)
		switch {
		case r == nil:
			fmt.eprintfln("there is no role called %s (`yap-server role list`)", role_name)
			return 1
		case r.id == proto.EVERYONE_ROLE:
			fmt.eprintln("everyone has that role, always")
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
		fmt.printfln("%s %s the role %s now", username, "has" if command == "role" else "doesn't have", r.name)
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
		fmt.println("no accounts yet: the server makes one called admin when it starts, or use `account add`")
		return
	}
	fmt.printfln("%-5s %-32s %-12s %-7s %-20s %s", "id", "username", "", "devices", "last here", "name")
	// By id, which is the order they were made in.
	ids, _ := slice.map_keys(a.by_id, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		acc := a.by_id[id]
		role := ""
		switch {
		case .Owner in acc.flags:
			role = "owner"
		case .Disabled in acc.flags:
			role = "disabled"
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
