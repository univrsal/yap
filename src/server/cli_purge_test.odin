package server

import "core:os"
import "core:testing"

// Tests of the helpers behind `purge` on the command line (cli_purge.odin).

@(test)
test_parse_before_days_ago :: proc(t: ^testing.T) {
	before := unix_ms()
	ms, ok := parse_before("30d")
	after := unix_ms()
	testing.expect(t, ok)
	testing.expect(t, ms >= before - 30 * DAY_MS && ms <= after - 30 * DAY_MS)

	ms, ok = parse_before("0d")
	testing.expect(t, ok)
	testing.expect(t, ms >= before && ms <= unix_ms())

	for bad in ([]string{"d", "-1d", "1.5d", "xd", "30 d", "d30", ""}) {
		_, ok = parse_before(bad)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}
}

@(test)
test_parse_before_day :: proc(t: ^testing.T) {
	// Midnight UTC.
	ms, ok := parse_before("2026-09-01")
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(1788220800000))
	ms, ok = parse_before("1970-01-01")
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(0))
	ms, ok = parse_before("2024-02-29") // a leap day
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(1709164800000))

	for bad in ([]string {
			"2026-13-01",
			"2026-00-10",
			"2026-02-30",
			"2025-02-29",
			"2026-09",
			"2026-09-01-02",
			"2026/09/01",
			"yesterday",
			"2026-09-xx",
		}) {
		_, ok = parse_before(bad)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}
}

@(test)
test_format_day :: proc(t: ^testing.T) {
	testing.expect_value(t, format_day(0), "1970-01-01 00:00 UTC")
	testing.expect_value(t, format_day(1788220800000), "2026-09-01 00:00 UTC")
	testing.expect_value(t, format_day(1788220800000 + 13 * 3600_000 + 5 * 60_000), "2026-09-01 13:05 UTC")

	// The date that was parsed is the date that is shown.
	ms, ok := parse_before("2026-12-31")
	testing.expect(t, ok)
	testing.expect_value(t, format_day(ms), "2026-12-31 00:00 UTC")
}

@(test)
test_megabytes :: proc(t: ^testing.T) {
	testing.expect_value(t, megabytes(0), "0.0 MB")
	testing.expect_value(t, megabytes(1024 * 1024), "1.0 MB")
	testing.expect_value(t, megabytes(1536 * 1024), "1.5 MB")
	testing.expect_value(t, megabytes(100 * 1024 * 1024), "100.0 MB")
}

@(test)
test_db_files_size :: proc(t: ^testing.T) {
	dir := test_dir(t)
	defer os.remove_all(dir)
	path := file_in(dir, "yap.db")

	testing.expect_value(t, db_files_size(path), i64(0))
	testing.expect(t, os.write_entire_file(path, make([]u8, 1000, context.temp_allocator)) == nil)
	testing.expect_value(t, db_files_size(path), i64(1000))
	// The write-ahead log counts too.
	testing.expect(
		t,
		os.write_entire_file(file_in(dir, "yap.db-wal"), make([]u8, 234, context.temp_allocator)) == nil,
	)
	testing.expect_value(t, db_files_size(path), i64(1234))
}
