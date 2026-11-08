package main

import "core:strings"
import "core:testing"

import "client:conn"

@(private = "file")
test_view :: proc() -> conn.View {
	v: conn.View
	conn.view_init(&v)
	v.server = strings.clone("example.org:7777")
	return v
}

@(test)
test_snapshot_connecting :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	v.status = .Connecting
	text, failed := snapshot(&v)
	defer delete(text)
	testing.expect_value(t, text, "example.org:7777: connecting...\n")
	testing.expect(t, !failed)
}

@(test)
test_snapshot_failed_for_good :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	v.status = .Failed
	v.error = strings.clone("refused")
	text, failed := snapshot(&v)
	defer delete(text)
	testing.expect_value(t, text, "example.org:7777: refused\n")
	testing.expect(t, failed)

	// A connection that is trying again is not over.
	v.retrying = true
	text2, failed2 := snapshot(&v)
	defer delete(text2)
	testing.expect_value(t, text2, "example.org:7777: refused (trying again)\n")
	testing.expect(t, !failed2)
}

@(test)
test_snapshot_channels :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	v.status = .Connected
	v.login.state = .Done
	v.my_name = strings.clone("anna")
	append(
		&v.channels,
		conn.View_Channel{name = strings.clone("general"), unread = 3, mentions = 1},
	)
	append(
		&v.channels,
		conn.View_Channel{name = strings.clone("dev"), topic = strings.clone("code")},
	)
	text, failed := snapshot(&v)
	defer delete(text)
	testing.expect_value(
		t,
		text,
		"example.org:7777: connected\n  logged in as anna\n  #general  3 unread, 1 mentions\n  #dev  - code\n",
	)
	testing.expect(t, !failed)
}

@(test)
test_snapshot_login_needed :: proc(t: ^testing.T) {
	v := test_view()
	defer conn.view_destroy(&v)
	v.status = .Connected
	v.login.state = .Needed
	text, _ := snapshot(&v)
	defer delete(text)
	testing.expect(t, strings.contains(text, "not logged in"))
}
