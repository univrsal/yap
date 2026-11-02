#+build !wasi
package conn

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests of what scripts are told about a connection (events.odin), and of the
// protocol events that tell them.

@(private = "file")
disconnected :: proc(n: int) -> Event {
	return Event_Disconnected{why = strings.clone(fmt.tprintf("%d", n))}
}

@(private = "file")
message_body :: proc(m: proto.Message) -> []u8 {
	buf := make([]u8, 4096, context.temp_allocator)
	return proto.encode_message(buf, m)
}

@(private = "file")
account_body :: proc(a: proto.Account) -> []u8 {
	buf := make([]u8, 1024, context.temp_allocator)
	return proto.encode_account(buf, a)
}

@(test)
test_sink_order_and_take :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	testing.expect_value(t, len(tc_events(&tc)), 0)
	event_connected(&tc.c)
	event_disconnected(&tc.c, "gone")
	event_put(&tc.c, disconnected(3))

	taken := sink_take(&tc.sink)
	defer delete(taken)
	testing.expect_value(t, len(taken), 3)
	_, is_connected := taken[0].(Event_Connected)
	testing.expect(t, is_connected, "events are not oldest first")
	if d, ok := taken[1].(Event_Disconnected); ok {
		testing.expect_value(t, d.why, "gone")
	} else {
		testing.fail(t)
	}
	for &e in taken {
		event_destroy(&e)
	}

	// Taking empties the sink.
	testing.expect_value(t, len(tc_events(&tc)), 0)
}

@(test)
test_sink_drops_the_oldest :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)

	// A script that never takes its events doesn't make the client grow.
	extra := 5
	for i in 0 ..< MAX_QUEUED_EVENTS + extra {
		event_put(&tc.c, disconnected(i))
	}
	taken := tc_events(&tc)
	testing.expect_value(t, len(taken), MAX_QUEUED_EVENTS)
	if d, ok := taken[0].(Event_Disconnected); ok {
		testing.expect_value(t, d.why, fmt.tprintf("%d", extra))
	}
	if d, ok := taken[len(taken) - 1].(Event_Disconnected); ok {
		testing.expect_value(t, d.why, fmt.tprintf("%d", MAX_QUEUED_EVENTS + extra - 1))
	}
	for &e in taken {
		event_destroy(&e)
	}
}

@(test)
test_no_sink_no_events :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	tc.c.events = nil
	tc_conv(&tc, 1, "Lobby")
	tc_account(&tc, 2, "alice")

	event_connected(&tc.c)
	event_disconnected(&tc.c, "gone")
	tc_event(&tc, .Msg_New, message_body({id = 1, conv = 1, sender = 2, kind = .Text, text = "hi"}))
	testing.expect_value(t, len(tc_events(&tc)), 0)
}

@(test)
test_message_event :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.auth.me = 1
	tc_conv(&tc, 1, "Lobby")
	tc_account(&tc, 1, "bob", "Bob")
	tc_account(&tc, 2, "alice", "Alice")

	tc_event(
		&tc,
		.Msg_New,
		message_body({id = 1, conv = 1, sender = 2, time = 1000, kind = .Text, text = "hello"}),
	)
	events := tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	if m, ok := events[0].(Event_Message); ok {
		testing.expect_value(t, m.id, proto.Msg_Id(1))
		testing.expect_value(t, m.conv, proto.Conv_Id(1))
		testing.expect_value(t, m.channel, "Lobby")
		testing.expect_value(t, m.author, proto.Account_Id(2))
		testing.expect_value(t, m.author_name, "Alice")
		testing.expect_value(t, m.username, "alice")
		testing.expect_value(t, m.text, "hello")
		testing.expect_value(t, m.time, proto.Unix_Ms(1000))
		testing.expect(t, !m.mine && !m.mentions_me)
	} else {
		testing.fail_now(t, "no message event")
	}
	for &e in events {
		event_destroy(&e)
	}

	// A message that mentions us says so, shown with the display name instead of the token.
	text := fmt.tprintf("hey %s, look", proto.mention_token(1))
	tc_event(&tc, .Msg_New, message_body({id = 2, conv = 1, sender = 2, kind = .Text, text = text}))
	// Ours is ours.
	tc_event(&tc, .Msg_New, message_body({id = 3, conv = 1, sender = 1, kind = .Text, text = "mine"}))
	events = tc_events(&tc)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		m, _ := events[0].(Event_Message)
		testing.expect(t, m.mentions_me, "a mention of us was missed")
		testing.expect_value(t, m.text, "hey @Bob, look")
		own, _ := events[1].(Event_Message)
		testing.expect(t, own.mine && !own.mentions_me)
	}
	for &e in events {
		event_destroy(&e)
	}

	// The same message arriving again (once as our post's answer, once as the
	// announcement) is told once.
	tc_event(&tc, .Msg_New, message_body({id = 3, conv = 1, sender = 1, kind = .Text, text = "mine"}))
	testing.expect_value(t, len(tc_events(&tc)), 0)
}

@(test)
test_presence_event :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	c := &tc.c
	c.auth.me = 1
	record := proto.Account {
		id       = 2,
		username = "alice",
		display  = "Alice",
	}

	// Learning who is there while logging in is not news.
	c.auth.state = .Working
	tc_event(&tc, .Account_Changed, account_body(record))
	c.auth.state = .Done
	testing.expect_value(t, len(tc_events(&tc)), 0)

	// Going away is.
	record.activity = .Away
	tc_event(&tc, .Account_Changed, account_body(record))
	events := tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	if p, ok := events[0].(Event_Presence); ok {
		testing.expect_value(t, p.account, proto.Account_Id(2))
		testing.expect_value(t, p.name, "Alice")
		testing.expect_value(t, p.username, "alice")
		testing.expect_value(t, p.activity, proto.Activity.Away)
		testing.expect_value(t, p.was, proto.Activity.Online)
	} else {
		testing.fail_now(t, "no presence event")
	}
	for &e in events {
		event_destroy(&e)
	}

	// A change that isn't one of activity, and our own, are not.
	record.display = "Alice B."
	tc_event(&tc, .Account_Changed, account_body(record))
	record.id, record.username, record.activity = 1, "bob", .Busy
	tc_event(&tc, .Account_Changed, account_body(record))
	testing.expect_value(t, len(tc_events(&tc)), 0)

	// Coming back reports where they were.
	record = {
		id       = 2,
		username = "alice",
		display  = "Alice B.",
		activity = .Online,
	}
	tc_event(&tc, .Account_Changed, account_body(record))
	events = tc_events(&tc)
	testing.expect_value(t, len(events), 1)
	if p, ok := events[0].(Event_Presence); ok {
		testing.expect_value(t, p.activity, proto.Activity.Online)
		testing.expect_value(t, p.was, proto.Activity.Away)
	}
	for &e in events {
		event_destroy(&e)
	}
}
