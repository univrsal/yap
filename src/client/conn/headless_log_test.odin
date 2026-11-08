#+build !wasi
package conn

import "core:log"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests of what headless mode logs (headless_log.odin), which is all a person
// or a script reading the command-line client sees, and that nothing is logged
// when there is a View to show it instead.

// Captured holds the lines logged from outside the test files. What the
// tests themselves log (their failures) still goes to the real logger.
@(private = "file")
Captured :: struct {
	inner: log.Logger,
	lines: [dynamic]string,
}

@(private = "file")
capture :: proc(cap: ^Captured) -> log.Logger {
	cap.inner = context.logger
	return {procedure = captured_log, data = cap, lowest_level = .Info}
}

@(private = "file")
captured_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	cap := (^Captured)(data)
	if strings.has_suffix(location.file_path, "_test.odin") {
		cap.inner.procedure(cap.inner.data, level, text, options, location)
		return
	}
	append(&cap.lines, strings.clone(text))
}

// taken returns the lines logged since it was last called.
@(private = "file")
taken :: proc(cap: ^Captured) -> []string {
	lines := make([]string, len(cap.lines), context.temp_allocator)
	for l, i in cap.lines {
		lines[i] = strings.clone(l, context.temp_allocator)
		delete(l)
	}
	clear(&cap.lines)
	return lines
}

@(private = "file")
captured_destroy :: proc(cap: ^Captured) {
	for l in cap.lines {
		delete(l)
	}
	delete(cap.lines)
}

@(private = "file")
expect_lines :: proc(t: ^testing.T, cap: ^Captured, want: ..string, loc := #caller_location) {
	got := taken(cap)
	if !testing.expectf(t, len(got) == len(want), "logged %v, not %v", got, want, loc = loc) {
		return
	}
	for w, i in want {
		testing.expect_value(t, got[i], w, loc = loc)
	}
}

@(private = "file")
open_headless :: proc(tc: ^Test_Conn) {
	tc_open(tc)
	tc.c.auth.me = 1
	tc_account(tc, 1, "root")
	tc_account(tc, 2, "alice", "Alice")
	tc_account(tc, 3, "bob")
	tc_conv(tc, 4, "Lobby")
	tc_dm_with(tc, 6, 1, 2)
}

@(test)
test_report_messages :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_headless(&tc)
	defer tc_close(&tc)
	c := &tc.c
	cap: Captured
	context.logger = capture(&cap)
	defer captured_destroy(&cap)

	m := proto.Message {
		id     = 10,
		conv   = 4,
		sender = 2,
		kind   = .Text,
		text   = "hello",
	}
	report_message(c, m)
	in_thread := m
	in_thread.id, in_thread.thread_root, in_thread.text = 11, 10, "re"
	report_message(c, in_thread)
	in_dm := m
	in_dm.conv, in_dm.flags, in_dm.persona.name = 6, {.Persona}, "Clippy"
	report_message(c, in_dm)
	expect_lines(
		t,
		&cap,
		"[chat] Lobby Alice (#10): hello",
		"[chat] Lobby Alice (#11, in the thread of #10): re",
		"[chat] DMs with Alice Clippy (via Alice) (#10): hello",
	)

	changed := m
	changed.edited = 1
	report_changed(c, changed)
	report_mention(c, m, "hi @root")
	report_typing(c, 4, 0, 3)
	report_typing(c, 4, 10, 3)
	expect_lines(
		t,
		&cap,
		"[chat] Lobby, message #10 is now: hello (edited)",
		"[mention] Alice mentioned you in Lobby: hi @root",
		"[chat] bob is typing in Lobby",
		"[chat] bob is typing in Lobby, in the thread of #10",
	)

	// A conversation we don't know is named by its number.
	unknown := m
	unknown.conv = 99
	report_message(c, unknown)
	expect_lines(t, &cap, "[chat] channel #99 Alice (#10): hello")

	// With a View, the UI shows these instead.
	_ = tc_view(&tc)
	report_message(c, m)
	report_changed(c, m)
	report_typing(c, 4, 0, 3)
	expect_lines(t, &cap)
}

@(test)
test_describe :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_headless(&tc)
	defer tc_close(&tc)
	c := &tc.c

	m := proto.Message {
		id     = 10,
		conv   = 4,
		sender = 2,
		kind   = .Text,
		text   = "hi",
	}
	testing.expect_value(t, describe(c, m), "hi")
	deleted := m
	deleted.flags = {.Deleted, .Pinned}
	testing.expect_value(t, describe(c, deleted), "(deleted)")

	marked := m
	marked.edited = 1
	marked.flags = {.Pinned, .Has_Thread}
	marked.reply_count = 3
	testing.expect_value(t, describe(c, marked), "hi (edited) (pinned) (3 replies)")

	forwarded := m
	forwarded.flags = {.Forwarded}
	forwarded.forward = {
		sender = 3,
		conv   = 4,
	}
	testing.expect_value(t, describe(c, forwarded), "hi (forwarded from bob, #4)")

	files := m
	files.flags = {.Has_Attachments}
	files.attachment_count = 2
	files.attachments[0] = {
		blob = 5,
		size = 2048,
		name = "a.txt",
	}
	files.attachments[1] = {
		blob = 0,
		size = 9,
		name = "gone.bin",
	}
	testing.expect_value(
		t,
		describe(c, files),
		`hi [file 1: "a.txt", 2 KB] [file 2: "gone.bin", no longer kept]`,
	)

	offer := proto.Message {
		kind      = .File,
		sender    = 2,
		file_name = "x.zip",
		file_size = 3 << 19,
	}
	testing.expect_value(t, describe(c, offer), `offers the file "x.zip" (1.5 MB)`)

	call := proto.Message {
		kind       = .System,
		sender     = 1,
		system     = u8(proto.Call_System.Ended),
		system_arg = 65,
	}
	testing.expect_value(t, describe(c, call), "Call lasted 1:05")
}

@(test)
test_report_lists :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_headless(&tc)
	defer tc_close(&tc)
	c := &tc.c
	cap: Captured
	context.logger = capture(&cap)
	defer captured_destroy(&cap)

	report_browse(c, "", 0, nil, false)
	report_browse(c, "music", 0, nil, false)
	report_browse(c, "", 2, {{name = "Music", topic = "tunes"}, {name = "Quiet"}}, true)
	expect_lines(
		t,
		&cap,
		"there are no other channels to subscribe to",
		"no other channel has that in its name or topic",
		`can subscribe to "Music": tunes`,
		`can subscribe to "Quiet"`,
		"and more (/browse more)",
	)

	page := []proto.Message{{id = 5}, {id = 6}}
	report_history(c, {4, 0}, nil, false, 0)
	report_history(c, {4, 10}, page, true, 7)
	report_history(c, {4, 0}, page, false, 2)
	expect_lines(
		t,
		&cap,
		"[history] Lobby: no messages",
		"[history] Lobby, thread #10: 2 messages (5 to 6), back to the first, 7 in all",
		"[history] Lobby: 2 messages (5 to 6), 2 in all",
	)

	// Only the first page says that nothing is pinned.
	report_pins(c, 4, nil, true)
	report_pins(c, 4, nil, false)
	report_pins(c, 4, {{id = 8, sender = 3, kind = .Text, text = "rules"}}, true)
	expect_lines(t, &cap, "[pins] Lobby: nothing pinned", "[pins] Lobby bob (#8): rules")

	report_search(c, "cats", 0, nil, false)
	report_search(c, "cats", 50, nil, false) // a later page that found nothing more
	report_search(c, "cats", 9, {{id = 9, conv = 4, sender = 2, text = "cats!"}}, true)
	expect_lines(
		t,
		&cap,
		`[search] nothing has "cats"`,
		"[search] Lobby Alice (#9): cats!",
		"[search] and maybe more (/search more)",
	)

	report_purged(c, {conv = 4, before = 100})
	report_purged(c, {conv = 4, author = 3, from = 20})
	expect_lines(
		t,
		&cap,
		"[chat] Lobby: the messages below #100 were purged",
		"[chat] Lobby: bob's messages from #20 on were purged",
	)

	acc := c.auth.accounts[3]
	acc.status = strings.clone("on holiday")
	c.auth.accounts[3] = acc
	report_members(c, 4, {2, 3}, {2})
	expect_lines(t, &cap, "[members] Lobby: Alice (admin)", "[members] Lobby: bob - on holiday")

	buf: [proto.ROLE_MAX_SIZE]u8
	tc_event(&tc, .Role_Changed, proto.encode_role(buf[:], {id = 10, name = "Mods"}))
	_ = taken(&cap) // the roles are logged as they arrive
	report_rights(c, {{10, {.See, .Write}}, {11, {}}})
	expect_lines(t, &cap, "[rights] Mods: see, write", "[rights] role 11: none")
}

@(test)
test_report_status_and_calls :: proc(t: ^testing.T) {
	tc: Test_Conn
	open_headless(&tc)
	defer tc_close(&tc)
	c := &tc.c
	cap: Captured
	context.logger = capture(&cap)
	defer captured_destroy(&cap)

	report_status(c, "Alice", "", 0)
	report_status(c, "Alice", "busy", 0)
	report_status(c, "Alice", "lunch", 12345)
	report_call_active(c, 2, true)
	report_call_active(c, 2, false)
	report_call_over(c, 2, .Declined)
	expect_lines(
		t,
		&cap,
		"[status] Alice has no status",
		"[status] Alice: busy",
		"[status] Alice: lunch (for a while)",
		"[call] in a call with Alice",
		"[call] in a call with Alice (on another device)",
		"[call] the call with Alice is over (Declined)",
	)

	_ = tc_view(&tc)
	report_status(c, "Alice", "busy", 0)
	report_call_over(c, 2, .Declined)
	expect_lines(t, &cap)
}
