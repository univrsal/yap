package server

import "core:testing"
import "core:time"

import "common:proto"

// Tests of calls, on the Test_Server of auth_test.odin.

@(private = "file")
call_start :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, to: proto.Account_Id) -> (proto.Status, proto.Call_Id) {
	buf: [4]u8
	status, body := ts_ask(t, ts, u, .Call_Start, proto.encode_account_id(&buf, to))
	id, _ := proto.decode_call_id(body)
	return status, id
}

@(private = "file")
call_ask :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, op: proto.Request_Op, id: proto.Call_Id) -> proto.Status {
	buf: [4]u8
	status, _ := ts_ask(t, ts, u, op, proto.encode_call_id(&buf, id))
	return status
}

// call_events is what a connection was told of calls since the last
// look: whether it rang, and the last change.
@(private = "file")
call_events :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn) -> (rang: bool, change: proto.Call_Change, changed: bool) {
	for e in ts_events(t, ts, u) {
		#partial switch e.op {
		case .Call_Ring:
			rang = true
		case .Call_Changed:
			c, ok := proto.decode_call_changed(e.body)
			testing.expect(t, ok)
			change, changed = c, true
		}
	}
	return
}

// last_note is the newest message of the DM between two accounts: the
// line a call left there.
@(private = "file")
last_note :: proc(t: ^testing.T, ts: ^Test_Server, a, b: proto.Account_Id) -> (m: proto.Message, ok: bool) {
	conv := dm_find(&ts.s.convs, a, b)
	if conv == nil || conv.last_msg == 0 {
		return
	}
	return msg_by_id(&ts.s, conv.last_msg)
}

@(private = "file")
age :: proc(tick: ^time.Tick, by: time.Duration) {
	tick._nsec -= i64(by)
}

@(test)
test_calls :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	laptop := logged_in(t, &ts, "bob")
	phone := logged_in(t, &ts, "bob")

	// Nobody to ring: a missed call.
	status, _ := call_start(t, &ts, alice, carol_acc.id)
	testing.expect_value(t, status, proto.Status.Closed)
	note, found := last_note(t, &ts, alice_acc.id, carol_acc.id)
	testing.expect(t, found && note.kind == .System && note.system == u8(proto.Call_System.Missed) && note.sender == alice_acc.id)
	status, _ = call_start(t, &ts, alice, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = call_start(t, &ts, alice, 999)
	testing.expect_value(t, status, proto.Status.Not_Found)

	// It rings on every device of bob's, and the caller hears it does.
	call: proto.Call_Id
	status, call = call_start(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	for u in ([]^Conn{laptop, phone}) {
		rang, change, _ := call_events(t, &ts, u)
		testing.expect(t, rang, "a device of bob's didn't ring")
		testing.expect(t, change.state == .Ringing && change.caller == alice_acc.id && change.callee == bob_acc.id)
	}
	_, change, changed := call_events(t, &ts, alice)
	testing.expect(t, changed && change.state == .Ringing)
	// Busy, either of them.
	carol := logged_in(t, &ts, "carol")
	status, _ = call_start(t, &ts, carol, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Conflict)
	status, _ = call_start(t, &ts, carol, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Conflict)

	// Answered on the phone: it and alice are in the call's room; the
	// laptop stops ringing, and can't answer as well.
	testing.expect_value(t, call_ask(t, &ts, carol, .Call_Accept, call), proto.Status.Not_Found)
	testing.expect_value(t, call_ask(t, &ts, phone, .Call_Accept, call), proto.Status.Ok)
	room := proto.call_room(call)
	testing.expect_value(t, phone.room, room)
	testing.expect_value(t, alice.room, room)
	testing.expect_value(t, laptop.room, 0)
	_, change, _ = call_events(t, &ts, laptop)
	testing.expect_value(t, change.state, proto.Call_State.Active)
	testing.expect_value(t, call_ask(t, &ts, laptop, .Call_Accept, call), proto.Status.Conflict)
	// Who is in it is theirs alone to see.
	testing.expect(t, !room_hidden(s, room, alice_acc.id))
	testing.expect(t, !room_hidden(s, room, bob_acc.id))
	testing.expect(t, room_hidden(s, room, carol_acc.id))
	// Nobody else can join it.
	room_buf: [4]u8
	status, _ = ts_ask(t, &ts, carol, .Voice_Join, proto.encode_room(&room_buf, room))
	testing.expect_value(t, status, proto.Status.Not_Found)

	// Hung up after a minute: both out, and how long it was.
	age(&s.calls.by_id[call].answered, 65 * time.Second)
	ts_events(t, &ts, alice)
	testing.expect_value(t, call_ask(t, &ts, phone, .Call_End, call), proto.Status.Ok)
	testing.expect(t, phone.room == 0 && alice.room == 0)
	_, change, _ = call_events(t, &ts, alice)
	testing.expect(t, change.state == .Ended && change.reason == .Hung_Up)
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect(t, note.system == u8(proto.Call_System.Ended) && note.system_arg >= 65)
	testing.expect_value(t, len(s.calls.by_id), 0)

	// Cancelled while ringing: missed. Declined: declined.
	_, call = call_start(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, call_ask(t, &ts, alice, .Call_End, call), proto.Status.Ok)
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect_value(t, note.system, u8(proto.Call_System.Missed))
	_, call = call_start(t, &ts, alice, bob_acc.id)
	ts_events(t, &ts, alice)
	testing.expect_value(t, call_ask(t, &ts, laptop, .Call_End, call), proto.Status.Ok)
	_, change, _ = call_events(t, &ts, alice)
	testing.expect_value(t, change.reason, proto.Call_End_Reason.Declined)
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect_value(t, note.system, u8(proto.Call_System.Declined))

	// Nobody answers in time: missed.
	_, call = call_start(t, &ts, alice, bob_acc.id)
	calls_sync(s)
	testing.expect(t, call in s.calls.by_id, "ended before its time")
	age(&s.calls.by_id[call].rang, (proto.CALL_RING_SECONDS + 1) * time.Second)
	ts_events(t, &ts, alice)
	calls_sync(s)
	testing.expect(t, call not_in s.calls.by_id)
	_, change, _ = call_events(t, &ts, alice)
	testing.expect_value(t, change.reason, proto.Call_End_Reason.Unanswered)
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect_value(t, note.system, u8(proto.Call_System.Missed))

	// Joining a channel's voice ends it.
	_, call = call_start(t, &ts, alice, bob_acc.id)
	call_ask(t, &ts, laptop, .Call_Accept, call)
	status, _ = ts_ask(t, &ts, laptop, .Voice_Join, proto.encode_room(&room_buf, proto.Room(s.convs.home.id)))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, call not_in s.calls.by_id)
	testing.expect_value(t, alice.room, 0)
	testing.expect_value(t, laptop.room, proto.Room(s.convs.home.id))
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect_value(t, note.system, u8(proto.Call_System.Ended))

	// Calling from a channel's room: the call takes the connection out
	// of it once answered.
	_, call = call_start(t, &ts, laptop, alice_acc.id)
	call_ask(t, &ts, alice, .Call_Accept, call)
	testing.expect_value(t, laptop.room, proto.call_room(call))
	call_ask(t, &ts, alice, .Call_End, call)

	// The caller going while it rings: missed.
	_, call = call_start(t, &ts, alice, bob_acc.id)
	ts_disconnect(&ts, alice)
	testing.expect(t, call not_in s.calls.by_id)
	note, _ = last_note(t, &ts, alice_acc.id, bob_acc.id)
	testing.expect_value(t, note.system, u8(proto.Call_System.Missed))

	// The line it leaves comes back with the history, as it was.
	history_buf: [proto.MSG_HISTORY_SIZE]u8
	conv := dm_find(&s.convs, alice_acc.id, bob_acc.id)
	status2, body := ts_ask(t, &ts, laptop, .Msg_History, proto.encode_msg_history(&history_buf, {conv = conv.id, limit = proto.MAX_HISTORY_LIMIT}))
	testing.expect_value(t, status2, proto.Status.Ok)
	page_buf := make([]proto.Message, proto.MAX_HISTORY_LIMIT, context.temp_allocator)
	_, page, _ := proto.decode_history_page(body, page_buf)
	ended := 0
	for m in page {
		if m.kind == .System && m.system == u8(proto.Call_System.Ended) && m.system_arg >= 65 {
			ended += 1
		}
	}
	testing.expect_value(t, ended, 1)
}

@(test)
test_calls_crossed :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	alice_acc := ts_account(t, &ts, "alice", "a password")
	bob_acc := ts_account(t, &ts, "bob", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")

	// Both call at once: the second is the answer to the first.
	status, call := call_start(t, &ts, alice, bob_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	again: proto.Call_Id
	status, again = call_start(t, &ts, bob, alice_acc.id)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, again, call)
	testing.expect_value(t, s.calls.by_id[call].state, proto.Call_State.Active)
	testing.expect(t, alice.room == proto.call_room(call) && bob.room == proto.call_room(call))

	// The one that answered going ends it.
	ts_disconnect(&ts, bob)
	testing.expect_value(t, len(s.calls.by_id), 0)
	testing.expect_value(t, alice.room, 0)
}
