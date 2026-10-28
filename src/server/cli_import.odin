package server

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "mattermost"

// `yap-server import mattermost <export folder> --team <name> ...` imports a
// Mattermost server into an empty database (docs/design/mattermost-import.md).
//
//	yap-server import mattermost <export folder> --team <name>
//	    [--owner <username>] [--passwords <file.csv>] [--dry-run] [--yes] [config.json]
//
// <export folder>  the unpacked export (import.jsonl, data/, and extras.jsonl if
//                  there is one)
// --team           the team to import: a yap server is one community
// --owner          the account that becomes the server's owner (default: the
//                  first system admin of the export)
// --passwords      where the generated passwords are written (default:
//                  passwords.csv next to the config)
// --dry-run        only read the export and say what an import would do
// --yes            don't ask before importing
//
// The server has to be stopped, and the database one that a server has never
// been used with (a server that was started once, to make config.json, is fine:
// its first admin is replaced by the import's own accounts).
//
// The importer is built in steps (7a to 7g in the design note). So far it reads
// the export (--dry-run) and makes the accounts; --unfinished says that a
// database with only that is what is wanted, for trying it on one that is
// thrown away.

IMPORT_USAGE :: `usage: yap-server import mattermost <export folder> --team <name> [--owner <username>] [--passwords <file.csv>] [--dry-run] [--yes] [--unfinished] [config.json]`

Import_Args :: struct {
	folder:    string,
	team:      string,
	owner:     string,
	passwords: string,
	config:    string,
	dry_run:   bool,
	yes:       bool,
	// Import what is built so far (see above). Goes when the importer is done.
	unfinished: bool,
}

// parse_import_args reads what follows `import`. `ok` is false after a message
// was printed.
parse_import_args :: proc(args: []string) -> (a: Import_Args, ok: bool) {
	if len(args) == 0 || args[0] != "mattermost" {
		fmt.eprintln(IMPORT_USAGE)
		return
	}
	positional := make([dynamic]string, context.temp_allocator)
	rest := args[1:]
	for i := 0; i < len(rest); i += 1 {
		// A flag's value is in the same argument (--team=acme) or the next.
		name, _, value := strings.partition(rest[i], "=")
		inline := strings.contains_rune(rest[i], '=')
		switch name {
		case "--dry-run":
			a.dry_run = true
		case "--yes", "-y":
			a.yes = true
		case "--unfinished":
			a.unfinished = true
		case "--team", "--owner", "--passwords":
			if !inline {
				if i + 1 >= len(rest) {
					fmt.eprintfln("%s needs a value", name)
					return
				}
				i += 1
				value = rest[i]
			}
			switch name {
			case "--team":
				a.team = value
			case "--owner":
				a.owner = value
			case "--passwords":
				a.passwords = value
			}
		case:
			if strings.has_prefix(name, "-") {
				fmt.eprintfln("unknown option %s", name)
				fmt.eprintln(IMPORT_USAGE)
				return
			}
			append(&positional, rest[i])
		}
	}
	if len(positional) < 1 || len(positional) > 2 || a.team == "" {
		fmt.eprintln(IMPORT_USAGE)
		return
	}
	a.folder = positional[0]
	a.config = positional[1] if len(positional) == 2 else DEFAULT_CONFIG_FILE
	return a, true
}

run_import_command :: proc(args: []string) -> int {
	a, args_ok := parse_import_args(args)
	if !args_ok {
		return 2
	}
	if !os.is_directory(a.folder) {
		fmt.eprintfln(
			"%s isn't a folder. Unpack the export (a zip from `mmctl export download`) and name the folder with import.jsonl in it.",
			a.folder,
		)
		return 2
	}

	progress: Progress
	scan, err := mattermost.scan(
		{
			dir = a.folder,
			team = a.team,
			progress = proc(file: string, done, total: i64, data: rawptr) {
				p := (^Progress)(data)
				if p.label != file {
					if p.label != "" {
						progress_finish(p)
					}
					p^ = progress_start(file, bytes = true)
					p.label = file
				}
				progress_update(p, done, total)
			},
			progress_data = &progress,
		},
	)
	if progress.label != "" {
		progress_finish(&progress)
	}
	if err != "" {
		fmt.eprintfln("%s", err)
		return 1
	}
	defer mattermost.scan_destroy(scan)
	if plan_err := mattermost.build_plan(scan, a.owner); plan_err != "" {
		fmt.eprintfln("%s", plan_err)
		return 1
	}

	out := os.to_stream(os.stdout)
	mattermost.report_write(scan, io.to_writer(out))
	if a.dry_run {
		return 0
	}
	if !a.unfinished {
		fmt.eprintln(
			"\nThe importer is not finished: it can only make the accounts so far. Nothing was changed. (--unfinished imports what there is, into a database that is thrown away.)",
		)
		return 2
	}
	return import_run(a, scan)
}

// import_run does the import: into the database that the config names, in one
// transaction, which is undone if anything fails.
import_run :: proc(a: Import_Args, scan: ^mattermost.Scan) -> int {
	settings, config_ok := cli_config(a.config)
	if !config_ok {
		return 2
	}
	// The passwords go next to the config unless said otherwise.
	csv := a.passwords
	if csv == "" {
		dir := filepath.dir(a.config)
		csv, _ = filepath.join({dir, "passwords.csv"}, context.temp_allocator)
	}
	if os.exists(csv) {
		fmt.eprintfln(
			"%s exists already. Move it away, or name another file with --passwords: it must be new, as it holds passwords.",
			csv,
		)
		return 2
	}
	if !a.yes && !confirm(fmt.tprintf("import into %s?", settings.db_path)) {
		fmt.println("nothing imported")
		return 0
	}

	db: DB
	if !db_open(&db, settings.db_path) {
		return 1
	}
	defer db_close(&db)
	// Everything from here is one transaction.
	db_begin(&db)
	if err := import_precheck(&db); err != "" {
		db_rollback(&db)
		fmt.eprintfln("%s", err)
		return 1
	}
	accounts: Accounts
	if !accounts_load(&accounts, &db) {
		db_rollback(&db)
		return 1
	}
	defer accounts_destroy(&accounts)
	convs: Convs
	if !convs_load(&convs, &db, []string{DEFAULT_CHANNEL_NAME}, &accounts) {
		db_rollback(&db)
		return 1
	}
	defer convs_destroy(&convs)
	blobs: Blob_Store
	if !blob_store_open(&blobs, &db, settings.blobs_dir) {
		db_rollback(&db)
		return 1
	}
	defer blob_store_close(&blobs)

	im := Importer {
		scan     = scan,
		db       = &db,
		accounts = &accounts,
		convs    = &convs,
		blobs    = &blobs,
	}
	importer_init(&im)
	defer importer_destroy(&im)

	if !import_accounts(&im) {
		import_undo(&im)
		fmt.eprintln("the import failed, and nothing was changed")
		return 1
	}
	if err := import_write_passwords(&im, csv); err != "" {
		import_undo(&im)
		fmt.eprintfln("%s\nnothing was changed", err)
		return 1
	}
	db_commit(&db)
	made := len(scan.plan.accounts) + len(scan.authors_gone)
	fmt.printfln(
		"\nmade %d accounts. Their passwords are in %s, which only you can read; hand them out and delete it. Everyone has to choose a new password when they first log in.",
		made,
		csv,
	)
	return 0
}
