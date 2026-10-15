package server

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:proto"
import "sqlite"

// `yap-server purge ...` purges messages from the command line while the
// server is stopped (see retention.odin for what is kept and what is removed).
//
//	yap-server purge <what> <before> [files] [-y] [config.json]
//
// <what>     all, a channel's name, or a DM written as alice+bob
// <before>   a day such as 2026-09-01 (midnight UTC), or a number of days ago
//            such as 30d
// files      only the files attached to messages are removed; the messages stay
//
// It reports what it would remove and asks for confirmation unless -y is given.
// Then it removes the messages, the stored files that are no longer used, and
// the free space in the database, and reports the result.

PURGE_USAGE :: `usage: yap-server purge <all|channel|alice+bob> <YYYY-MM-DD|<days>d> [files] [-y] [config.json]`

run_purge_command :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	yes, files := false, false
	for a in args {
		switch a {
		case "-y", "--yes":
			yes = true
		case "files", "attachments":
			files = true
		case:
			append(&positional, a)
		}
	}
	if len(positional) < 2 || len(positional) > 3 {
		fmt.eprintln(PURGE_USAGE)
		return 2
	}
	target, when_text := positional[0], positional[1]
	config := positional[2] if len(positional) == 3 else DEFAULT_CONFIG_FILE

	before, date_ok := parse_before(when_text)
	if !date_ok {
		fmt.eprintfln(
			"%q isn't a valid date (like 2026-09-01) or a number of days ago (like 30d)",
			when_text,
		)
		return 2
	}
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
	size_before := db_files_size(settings.db_path)

	db: DB
	if !db_open(&db, settings.db_path) {
		return 1
	}
	opened := true
	defer if opened {
		db_close(&db)
	}
	bs: Blob_Store
	if !blob_store_open(&bs, &db, settings.blobs_dir) {
		return 1
	}
	defer blob_store_close(&bs)
	a: Accounts
	if !accounts_load(&a, &db) {
		return 1
	}
	defer accounts_destroy(&a)
	convs: Convs
	if !convs_load(&convs, &db, []string{DEFAULT_CHANNEL_NAME}, &a) {
		return 1
	}
	defer convs_destroy(&convs)

	conv: ^Conv
	place := "every conversation"
	if target != "all" {
		conv = purge_target(&convs, &a, target)
		if conv == nil {
			return 1
		}
		place =
			fmt.tprintf("#%s", conv.name) if conv.kind == .Channel else fmt.tprintf("the DM %s", target)
	}

	r: Retention
	retention_open(&r, &db, {})
	defer retention_close(&r)
	if r.asked {
		// The server was in the middle of a purge, which has to finish first.
		fmt.println("first finishing a purge that the server did not complete")
		retention_drain(&r, &bs)
	}

	below := msg_boundary(&db, before)
	q := db_stmt(&db, .Purge_Count_Conv if conv != nil else .Purge_Count)
	db_bind_int(q, 1, i64(below))
	if conv != nil {
		db_bind_int(q, 2, i64(conv.id))
	}
	count, with_files: i64
	if row, ok := db_step(&db, q); ok && row {
		count = db_col_int(q, 0)
		sqlite.reset(q)
	}
	q = db_stmt(&db, .Purge_Count_Files_Conv if conv != nil else .Purge_Count_Files)
	db_bind_int(q, 1, i64(below))
	if conv != nil {
		db_bind_int(q, 2, i64(conv.id))
	}
	if row, ok := db_step(&db, q); ok && row {
		with_files = db_col_int(q, 0)
		sqlite.reset(q)
	}
	day := format_day(before)
	if files {
		fmt.printfln(
			"files attached to messages in %s from before %s: up to %d messages (pinned messages keep their files)",
			place,
			day,
			with_files,
		)
	} else {
		fmt.printfln(
			"messages in %s from before %s: up to %d, %d of them with files (pinned messages and threads with newer replies are kept)",
			place,
			day,
			count,
			with_files,
		)
	}
	if (with_files if files else count) == 0 {
		fmt.println("nothing to purge there; cleaning up unused files and database space")
	} else if !yes && !confirm("remove them permanently?") {
		fmt.println("nothing purged")
		return 0
	}

	p := proto.Purge {
		conv   = conv.id if conv != nil else 0,
		before = proto.Unix_Ms(before),
		what   = .Files if files else .Messages,
	}
	retention_ask(&r, &db, p, unix_ms())
	messages, blobs := retention_drain(&r, &bs)
	db_close(&db)
	opened = false
	fmt.printfln(
		"purged %d %s; removed %d stored file(s); the database size went from %s to %s",
		messages,
		"message file(s)" if files else "message(s)",
		blobs,
		megabytes(size_before),
		megabytes(db_files_size(settings.db_path)),
	)
	return 0
}

// purge_target returns the conversation named on the command line, which is
// either a channel or a DM written as alice+bob.
@(private = "file")
purge_target :: proc(convs: ^Convs, a: ^Accounts, name: string) -> ^Conv {
	if plus := strings.index_byte(name, '+'); plus > 0 {
		x := account_find(a, name[:plus])
		y := account_find(a, name[plus + 1:])
		if x == nil || y == nil {
			fmt.eprintfln("%s: no such account", name[:plus] if x == nil else name[plus + 1:])
			return nil
		}
		pair := [2]proto.Account_Id{min(x.id, y.id), max(x.id, y.id)}
		conv := convs.dms[pair] or_else nil
		if conv == nil {
			fmt.eprintfln("%s and %s have no DM with each other", x.username, y.username)
		}
		return conv
	}
	conv := conv_by_name(convs, strings.trim_prefix(name, "#"))
	if conv == nil {
		fmt.eprintfln(
			"there is no channel called %s (use \"all\" for everything, or alice+bob for a DM)",
			name,
		)
	}
	return conv
}

// parse_before reads either a day (such as 2026-09-01, meaning midnight UTC) or
// a number of days ago (such as 30d) and returns it as Unix milliseconds.
@(private = "file")
parse_before :: proc(text: string) -> (ms: i64, ok: bool) {
	if strings.has_suffix(text, "d") {
		days := strconv.parse_int(text[:len(text) - 1], 10) or_return
		if days < 0 {
			return
		}
		return unix_ms() - i64(days) * DAY_MS, true
	}
	parts := strings.split(text, "-", context.temp_allocator)
	if len(parts) != 3 {
		return
	}
	y := strconv.parse_int(parts[0], 10) or_return
	m := strconv.parse_int(parts[1], 10) or_return
	d := strconv.parse_int(parts[2], 10) or_return
	t := time.components_to_time(y, m, d, 0, 0, 0) or_return
	return time.time_to_unix_nano(t) / 1_000_000, true
}

@(private = "file")
format_day :: proc(ms: i64) -> string {
	t := time.unix(ms / 1000, 0)
	y, mon, d := time.date(t)
	h, m, _ := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mon), d, h, m)
}

// confirm asks a yes/no question on the terminal. Anything but "y" or "yes" counts as no.
@(private = "file")
confirm :: proc(question: string) -> bool {
	fmt.printf("%s [y/N] ", question)
	r: bufio.Reader
	bufio.reader_init(&r, io.to_reader(os.to_stream(os.stdin)), allocator = context.temp_allocator)
	line, err := bufio.reader_read_string(&r, '\n', context.temp_allocator)
	if err != nil && err != .EOF {
		return false
	}
	answer := strings.to_lower(strings.trim_space(line), context.temp_allocator)
	return answer == "y" || answer == "yes"
}

// db_files_size returns the disk space used by the database file and its
// write-ahead log.
@(private = "file")
db_files_size :: proc(path: string) -> i64 {
	total: i64
	for p in ([]string{path, strings.concatenate({path, "-wal"}, context.temp_allocator)}) {
		if info, err := os.stat(p, context.temp_allocator); err == nil {
			total += info.size
		}
	}
	return total
}

@(private = "file")
megabytes :: proc(n: i64) -> string {
	return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
}
