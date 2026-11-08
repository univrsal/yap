package server

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of what a connection is told when it logs in (directory.odin), the
// owner's memory report (memory.odin), the status line of long commands
// (progress.odin), and the environment that a container passes the server
// (main.odin).

// ---- the login sync ----

@(private = "file")
ops :: proc(events: []Test_Event) -> []proto.Event_Op {
	out := make([]proto.Event_Op, len(events), context.temp_allocator)
	for e, i in events {
		out[i] = e.op
	}
	return out
}

@(private = "file")
first_index :: proc(events: []Test_Event, op: proto.Event_Op) -> int {
	for e, i in events {
		if e.op == op {
			return i
		}
	}
	return -1
}

@(test)
test_login_sync_order :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	bob := ts_connect(&ts)
	status, _ := ts_login(t, &ts, bob, "bob", "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	events := ts_events(t, &ts, bob)

	// Clients clear what they know at the start and consider themselves
	// logged in at the end, so the order is part of the protocol.
	testing.expect(t, len(events) > 4)
	testing.expect_value(t, events[0].op, proto.Event_Op.Sync_Begin)
	testing.expect_value(t, events[len(events) - 1].op, proto.Event_Op.Sync_End)
	self := first_index(events, .Self)
	testing.expect(t, self > 0)
	testing.expect_value(t, self, len(events) - 2) // right before the end
	// Everyone is described before the conversations that name them.
	last_account, first_conv := -1, -1
	accounts := 0
	for e, i in events {
		#partial switch e.op {
		case .Account_Changed:
			last_account = i
			accounts += 1
		case .Conv_Changed:
			if first_conv < 0 {
				first_conv = i
			}
		}
	}
	testing.expect_value(t, accounts, 3)
	testing.expect(t, first_conv > last_account, "a conversation was described before everyone")
	// The accounts come in the order they were made.
	seen := make([dynamic]proto.Account_Id, context.temp_allocator)
	for e in events {
		if e.op == .Account_Changed {
			a, ok := proto.decode_account(e.body)
			testing.expect(t, ok)
			append(&seen, a.id)
		}
	}
	for i in 1 ..< len(seen) {
		testing.expect(t, seen[i] > seen[i - 1], "accounts out of order")
	}
	// The connection is told who it is.
	me_body := events[self].body
	me, _, _, ok := proto.decode_self(me_body)
	testing.expect(t, ok)
	testing.expect_value(t, me, bob_acc.id)
}

@(test)
test_account_changes_are_announced :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	alice2 := ts_connect(&ts)
	status, _ := ts_login(t, &ts, alice2, "alice", "a password")
	testing.expect_value(t, status, proto.Status.Ok)
	bob := logged_in(t, &ts, "bob")
	// (Bob logging in was news to the others too.)
	_ = ts_events(t, &ts, alice2)
	_ = ts_events(t, &ts, alice)

	// A change to an account is told to everyone, and to the account's own
	// connections about themselves as well.
	alice_acc.display = strings.clone("Alice A.")
	account_changed(&ts.s, alice_acc)
	for u in ([]^Conn{alice, alice2, bob}) {
		events := ts_events(t, &ts, u)
		changed, found := has_event(events, .Account_Changed)
		testing.expect(t, found)
		if found {
			a, ok := proto.decode_account(changed.body)
			testing.expect(t, ok)
			testing.expect_value(t, a.display, "Alice A.")
		}
		_, got_self := has_event(events, .Self)
		testing.expectf(t, got_self == (u != bob), "self: %v for %v", got_self, u.num)
	}

	// Telling about an account can leave one connection out, and sends nothing more.
	account_told(&ts.s, alice_acc, except = alice)
	testing.expect_value(t, len(ts_events(t, &ts, alice)), 0)
	events := ts_events(t, &ts, bob)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, len(ts_events(t, &ts, alice2)), 1)
}

// ---- memory ----

@(test)
test_memory_report_is_for_the_owner :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_account(t, &ts, "owner", "a password", {.Owner})
	ts_account(t, &ts, "alice", "a password")
	owner := logged_in(t, &ts, "owner")
	alice := logged_in(t, &ts, "alice")

	status, report := ts_ask(t, &ts, alice, .Server_Memory)
	testing.expect_value(t, status, proto.Status.Denied)
	testing.expect_value(t, len(report), 0)

	status, report = ts_ask(t, &ts, owner, .Server_Memory)
	testing.expect_value(t, status, proto.Status.Ok)
	text := string(report)
	testing.expect(t, len(text) > 0)
	testing.expect(t, len(text) <= proto.MAX_BODY_SIZE)
	// The database's memory is part of it, and a report ends at a line's end.
	testing.expect(t, strings.contains(text, "SQLite"), "the database is missing from the report")
	testing.expect(t, strings.has_suffix(text, "\n"))
}

@(test)
test_memory_summary_is_logged_at_an_interval :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s

	// Off: nothing, whatever the time.
	memory_log_open(s, 0)
	s.memory_log.logged = time.tick_add(time.tick_now(), -time.Hour)
	before := s.memory_log.logged
	memory_sync(s)
	testing.expect_value(t, s.memory_log.logged, before)

	// On, but not yet due.
	memory_log_open(s, time.Minute)
	opened := s.memory_log.logged
	memory_sync(s)
	testing.expect_value(t, s.memory_log.logged, opened)
	// Due: it is logged, and the clock restarts.
	s.memory_log.logged = time.tick_add(time.tick_now(), -(time.Minute + time.Second))
	stale := s.memory_log.logged
	memory_sync(s)
	testing.expect(t, s.memory_log.logged != stale)
	testing.expect(t, time.tick_since(s.memory_log.logged) < time.Second)
}

@(test)
test_memory_extras_need_a_database :: proc(t: ^testing.T) {
	s: Server
	testing.expect_value(t, len(memory_extras(&s)), 0)
}

// ---- the status line ----

@(test)
test_progress_is_not_printed_too_often :: proc(t: ^testing.T) {
	p := progress_start("reading", bytes = true)
	testing.expect_value(t, p.label, "reading")
	testing.expect(t, p.bytes)
	testing.expect_value(t, p.done, i64(0))

	// Updates are recorded, but only printed every PROGRESS_EVERY.
	last := p.last
	progress_update(&p, 100, 1000)
	testing.expect_value(t, p.done, i64(100))
	testing.expect_value(t, p.last, last)
	p.last = time.tick_add(time.tick_now(), -(PROGRESS_EVERY + time.Millisecond))
	stale := p.last
	progress_update(&p, 500, 1000)
	testing.expect_value(t, p.done, i64(500))
	testing.expect(t, p.last != stale)
	testing.expect(t, time.tick_since(p.last) < PROGRESS_EVERY)

	// A line is printed even for a phase with no known size, and finishing
	// forgets the phase.
	q := progress_start("scanning")
	q.last = time.tick_add(time.tick_now(), -(PROGRESS_EVERY + time.Millisecond))
	progress_update(&q, 50, 0)
	progress_finish(&p)
	testing.expect_value(t, p, Progress{})
	progress_finish(&q)
	testing.expect_value(t, q.label, "")
	// Finishing something that never started does no harm.
	nothing: Progress
	progress_finish(&nothing)
}

// ---- the environment ----

// All of the environment is set and read in one test, since the environment is
// shared by the tests that run at once.
@(test)
test_environment_for_a_new_server :: proc(t: ^testing.T) {
	// The commands load the config the way the server does, and keep it until
	// the process ends. Nothing here outlives the test, so its memory goes away
	// with the temp allocator instead of being reported as leaked.
	context.allocator = context.temp_allocator
	context.logger = expected_errors() // a bad value is logged as an error
	names := []string {
		"YAP_RELAY_ENABLED",
		"YAP_INITIAL_ADMIN_PASSWORD",
		"YAP_PORT",
		"YAP_VIDEO_PORT",
		"YAP_RELAY_PORT",
		"YAP_VIDEO_ENABLED",
		"YAP_RELAY_ALLOW_SITES",
	}
	for n in names {
		os.unset_env(n)
	}
	defer for n in names {
		os.unset_env(n)
	}
	set :: proc(name, value: string) {
		_ = os.set_env(name, value)
	}

	// Nothing set: nothing changes.
	b, ok := bootstrap_from_env()
	testing.expect(t, ok)
	testing.expect(t, !b.relay_enabled_set)
	testing.expect_value(t, b.initial_admin_password, "")
	p, ports_ok := ports_from_env()
	testing.expect(t, ports_ok)
	testing.expect_value(t, p.port, 0)
	testing.expect_value(t, p.video_port, 0)
	testing.expect_value(t, p.relay_port, 0)
	testing.expect(t, !p.video_enabled_set)
	testing.expect_value(t, len(p.allow_sites), 0)

	// Booleans in both spellings.
	for v in ([]struct {
			text: string,
			want: bool,
		}{{"true", true}, {"1", true}, {"false", false}, {"0", false}}) {
		set("YAP_RELAY_ENABLED", v.text)
		b, ok = bootstrap_from_env()
		testing.expectf(
			t,
			ok && b.relay_enabled_set && b.relay_enabled == v.want,
			"relay %q",
			v.text,
		)
		set("YAP_VIDEO_ENABLED", v.text)
		p, ports_ok = ports_from_env()
		testing.expectf(
			t,
			ports_ok && p.video_enabled_set && p.video_enabled == v.want,
			"video %q",
			v.text,
		)
	}
	for bad in ([]string{"yes", "TRUE", "2", "on"}) {
		set("YAP_RELAY_ENABLED", bad)
		_, ok = bootstrap_from_env()
		testing.expectf(t, !ok, "YAP_RELAY_ENABLED=%q was accepted", bad)
		set("YAP_VIDEO_ENABLED", bad)
		_, ports_ok = ports_from_env()
		testing.expectf(t, !ports_ok, "YAP_VIDEO_ENABLED=%q was accepted", bad)
	}
	os.unset_env("YAP_RELAY_ENABLED")
	os.unset_env("YAP_VIDEO_ENABLED")

	// The first admin's password has to be one an account may have.
	set("YAP_INITIAL_ADMIN_PASSWORD", "a good password")
	b, ok = bootstrap_from_env()
	testing.expect(t, ok)
	testing.expect_value(t, b.initial_admin_password, "a good password")
	set("YAP_INITIAL_ADMIN_PASSWORD", "short")
	_, ok = bootstrap_from_env()
	testing.expect(t, !ok)
	set(
		"YAP_INITIAL_ADMIN_PASSWORD",
		strings.repeat("p", proto.MAX_ACCOUNT_PASSWORD + 1, context.temp_allocator),
	)
	_, ok = bootstrap_from_env()
	testing.expect(t, !ok)
	os.unset_env("YAP_INITIAL_ADMIN_PASSWORD")

	// Ports are 1 to 65535.
	set("YAP_PORT", "7777")
	set("YAP_VIDEO_PORT", "7778")
	set("YAP_RELAY_PORT", "8080")
	p, ports_ok = ports_from_env()
	testing.expect(t, ports_ok)
	testing.expect_value(t, p.port, 7777)
	testing.expect_value(t, p.video_port, 7778)
	testing.expect_value(t, p.relay_port, 8080)
	for bad in ([]string{"0", "-1", "65536", "seven", "80 80", "1.5", " 80"}) {
		for name in ([]string{"YAP_PORT", "YAP_VIDEO_PORT", "YAP_RELAY_PORT"}) {
			set(name, bad)
			_, ports_ok = ports_from_env()
			testing.expectf(t, !ports_ok, "%s=%q was accepted", name, bad)
			set(name, "9000")
		}
	}
	set("YAP_PORT", "1")
	set("YAP_VIDEO_PORT", "65535")
	p, ports_ok = ports_from_env()
	testing.expect(t, ports_ok && p.port == 1 && p.video_port == 65535)

	// Sites separated by commas or blanks, in any mix.
	set(
		"YAP_RELAY_ALLOW_SITES",
		"https://a.example.org,https://b.example.org  https://c.example.org\n*,",
	)
	p, ports_ok = ports_from_env()
	testing.expect(t, ports_ok)
	testing.expect_value(t, len(p.allow_sites), 4)
	if len(p.allow_sites) == 4 {
		testing.expect_value(t, p.allow_sites[0], "https://a.example.org")
		testing.expect_value(t, p.allow_sites[2], "https://c.example.org")
		testing.expect_value(t, p.allow_sites[3], "*")
	}
}
