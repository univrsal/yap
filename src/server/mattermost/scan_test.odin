package mattermost

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The sample export of tools/mattermost (made from the test instance), which
// is also the importer's test data. Its numbers were counted again with a
// script that doesn't use this code.
SAMPLE :: #directory + "../../../tools/mattermost/sample"

@(test)
test_scan_sample :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)

	testing.expect(t, strings.has_prefix(s.info.version, "10.12.4"))
	testing.expect_value(t, len(s.teams), 2)
	testing.expect_value(t, len(s.users), 8)
	testing.expect_value(t, len(s.members), 7) // of acme; the eighth is in the other team
	testing.expect_value(t, len(s.bots), 3)
	testing.expect_value(t, len(s.channels), 6)
	testing.expect_value(t, len(s.directs), 6)
	testing.expect_value(t, s.directs_left, 1)

	st := s.stats
	testing.expect_value(t, st.posts, 79)
	testing.expect_value(t, st.posts_other_teams, 10)
	testing.expect_value(t, st.direct_posts, 9)
	testing.expect_value(t, st.direct_posts_left_out, 1)
	testing.expect_value(t, st.replies, 5)
	testing.expect_value(t, st.system, 49)
	testing.expect_value(t, st.pinned, 1)
	testing.expect_value(t, st.edited, 1)
	testing.expect_value(t, st.saved, 2)
	testing.expect_value(t, st.reactions, 9) // 7 in posts and 2 from extras.jsonl
	testing.expect_value(t, st.attachments, 4)
	testing.expect_value(t, st.first_time, 1793200875374)
	testing.expect_value(t, st.last_time, 1793200880092)
	testing.expect_value(t, len(s.emoji), 1)
	// One reference for each post and reply that pass 2 reads.
	testing.expect_value(t, len(s.posts), 79 + 9)

	// A deactivated member is still a member, and a bot is imported without
	// being in a team.
	testing.expect(t, imported(s, "buildbot"))
	testing.expect(t, !imported(s, "nobody"))
	deactivated := 0
	for u in s.users {
		if s.members[u.username] && u.delete_at != 0 {
			deactivated += 1
		}
	}
	testing.expect_value(t, deactivated, 1)

	// The one thing wrong with the sample: a DM with someone from the other team.
	testing.expect_value(t, s.issues[.Direct_Member_Gone].count, 1)
	testing.expect_value(t, s.issues[.Direct_Member_Gone].examples[0], "alice,erin")
	for kind in Issue_Kind {
		if kind != .Direct_Member_Gone {
			testing.expectf(t, s.issues[kind].count == 0, "%v: %d", kind, s.issues[kind].count)
		}
	}

	// Every reference points at the line of its post, which reads back.
	l: Lines
	testing.expect_value(t, lines_open(&l, fmt.tprintf("%s/%s", SAMPLE, IMPORT_FILE)), "")
	defer lines_close(&l)
	for ref in s.posts[:10] {
		line, ok := line_at(l.file, ref.offset, int(ref.length), context.temp_allocator)
		testing.expect(t, ok)
		testing.expect(t, strings.has_prefix(string(line), `{"type":"`))
		testing.expect(t, strings.contains(string(line), `"create_at":`))
	}
}

@(test)
test_scan_report :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	report_write(s, strings.to_stream(&b))
	text := strings.to_string(b)
	for want in ([]string {
			"Team: acme (Acme)",
			"7 from the team: 6 active, 1 deactivated",
			"3 bots",
			"6 channels: 5 open, 1 private, 1 archived",
			"6 direct: 3 DMs, 1 with oneself, 2 group messages",
			"79 in channels and 9 in direct channels",
			"alice,erin",
		}) {
		testing.expectf(t, strings.contains(text, want), "the report lacks %q:\n%s", want, text)
	}
}

@(test)
test_scan_progress :: proc(t: ^testing.T) {
	Seen :: struct {
		calls:     int,
		last_done: i64,
		total:     i64,
	}
	seen: Seen
	s, err := scan({
		dir = SAMPLE,
		team = "acme",
		progress = proc(file: string, done, total: i64, data: rawptr) {
			if file == IMPORT_FILE {
				p := (^Seen)(data)
				p.calls += 1
				p.last_done, p.total = done, total
			}
		},
		progress_data = &seen,
	})
	testing.expect_value(t, err, "")
	if s != nil {
		scan_destroy(s)
	}
	// It ends at the file's size, however few lines there were to report in
	// between.
	testing.expect(t, seen.calls >= 1)
	testing.expect(t, seen.total > 0)
	testing.expect_value(t, seen.last_done, seen.total)
}

@(test)
test_scan_wrong_team :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "nothere"})
	testing.expect(t, s == nil)
	testing.expect(t, strings.contains(err, `no team called "nothere"`))
	testing.expect(t, strings.contains(err, "acme") && strings.contains(err, "other"))
	delete(err)
}

// export_with writes an import.jsonl with `lines` in a new folder and returns it.
@(private = "file")
export_with :: proc(t: ^testing.T, lines: ..string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "yap-mm-*", context.temp_allocator)
	testing.expect(t, err == nil)
	text := strings.join(lines, "\n", context.temp_allocator)
	path, _ := filepath.join({dir, IMPORT_FILE}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, text) == nil)
	return dir
}

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
@(private = "file")
TEAM :: `{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`
@(private = "file")
CHANNEL :: `{"type":"channel","channel":{"team":"acme","name":"town-square","display_name":"Town Square","type":"O"}}`
@(private = "file")
USER :: `{"type":"user","user":{"username":"alice","roles":"system_user","teams":[{"name":"acme","roles":"team_user","channels":[]}]}}`

@(private = "file")
post :: proc(channel, user: string, at: int) -> string {
	return fmt.tprintf(
		`{{"type":"post","post":{{"team":"acme","channel":"%s","user":"%s","message":"hi","create_at":%d,"edit_at":0,"is_pinned":false}}}}`,
		channel,
		user,
		at,
	)
}

@(test)
test_scan_small :: proc(t: ^testing.T) {
	dir := export_with(
		t,
		VERSION,
		TEAM,
		CHANNEL,
		USER,
		post("town-square", "alice", 2000),
		post("town-square", "alice", 1000),
		post("town-square", "ghost", 3000), // no such user
		post("nowhere", "alice", 4000), // no such channel
		`{"type":"somethingnew","somethingnew":{}}`,
		"",
	)
	defer os.remove_all(dir)
	s, err := scan({dir = dir, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	testing.expect_value(t, s.stats.posts, 3)
	testing.expect_value(t, len(s.posts), 3)
	testing.expect_value(t, s.stats.first_time, 1000)
	testing.expect_value(t, s.stats.last_time, 3000)
	testing.expect_value(t, s.issues[.Author_Unknown].count, 1)
	testing.expect_value(t, s.issues[.Author_Unknown].examples[0], "ghost")
	testing.expect_value(t, s.issues[.Post_Channel_Unknown].count, 1)
	testing.expect_value(t, s.issues[.Unknown_Line].count, 1)
}

@(test)
test_scan_refuses :: proc(t: ^testing.T) {
	expect_error :: proc(t: ^testing.T, want: string, lines: ..string) {
		dir := export_with(t, ..lines)
		defer os.remove_all(dir)
		s, err := scan({dir = dir, team = "acme"})
		testing.expect(t, s == nil)
		testing.expectf(t, strings.contains(err, want), "wanted %q in %q", want, err)
		delete(err)
		if s != nil {
			scan_destroy(s)
		}
	}
	expect_error(t, "the first line has to be the version", TEAM, VERSION)
	expect_error(t, "format version 2", `{"type":"version","version":2,"info":{}}`, TEAM)
	// A line cut off in the middle, as a copy that didn't finish leaves it.
	expect_error(t, "line 4", VERSION, TEAM, CHANNEL, `{"type":"user","user":{"username":"ali`)
	expect_error(t, "is empty", "")
}

@(test)
test_scan_missing_folder :: proc(t: ^testing.T) {
	s, err := scan({dir = "/nonexistent/export", team = "acme"})
	testing.expect(t, s == nil)
	testing.expect(t, strings.contains(err, "import.jsonl"))
	delete(err)
}

@(test)
test_direct_key :: proc(t: ^testing.T) {
	testing.expect_value(t, direct_key({"bob", "alice"}), "alice,bob")
	testing.expect_value(t, direct_key({"alice", "alice"}), "alice")
	testing.expect_value(t, direct_key({"carol", "alice", "bob"}), "alice,bob,carol")
}
