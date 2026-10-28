package server

import "core:fmt"
import "core:io"
import "core:os"
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
// The server has to be stopped. For now only --dry-run works: the importer is
// built in steps (7a to 7g in the design note), and this is 7a, which reads.

IMPORT_USAGE :: `usage: yap-server import mattermost <export folder> --team <name> [--owner <username>] [--passwords <file.csv>] [--dry-run] [--yes] [config.json]`

Import_Args :: struct {
	folder:    string,
	team:      string,
	owner:     string,
	passwords: string,
	config:    string,
	dry_run:   bool,
	yes:       bool,
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

	out := os.to_stream(os.stdout)
	mattermost.report_write(scan, io.to_writer(out))
	if !a.dry_run {
		fmt.eprintln(
			"\nThe importer only reads for now: it can't write the yap database yet. Nothing was changed.",
		)
		return 2
	}
	return 0
}
