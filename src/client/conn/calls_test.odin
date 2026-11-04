#+build !wasi
package conn

import "core:testing"

import "client:audio"
import "common:proto"

// Tests of calls on our end (calls.odin): what is asked of the server to
// start, answer and end a call, how the call is tracked from the server's
// events, whether this connection is the one in it, and what the user is told.

@(private = "file")
open_caller :: proc(tc: ^Test_Conn) -> ^View {
	tc_open(tc)
	tc.c.auth.me = 1
	tc.c.auth.state = .Done
	tc_account(tc, 1, "root")
	tc_account(tc, 2, "alice", "Alice")
	return tc_view(tc)
}

@(private = "file")
call_changed :: proc(tc: ^Test_Conn, change: proto.Call_Change) {
	buf: [proto.CALL_CHANGED_SIZE]u8
	tc_event(tc, .Call_Changed, proto.encode_call_changed(&buf, change))
}

@(private = "file")
call_ring :: proc(tc: ^Test_Conn, id: proto.Call_Id, from: proto.Account_Id) {
	buf: [proto.CALL_RING_SIZE]u8
	tc_event(tc, .Call_Ring, proto.encode_call_ring(&buf, id, from))
}

@(private = "file")
call_id_answer :: proc(tc: ^Test_Conn, request: u32, id: proto.Call_Id) {
	buf: [4]u8
	tc_answer(tc, request, .Ok, proto.encode_call_id(&buf, id))
}

@(private = "file")
sent_call_id :: proc(t: ^testing.T, tc: ^Test_Conn, op: proto.Request_Op) -> proto.Call_Id {
	r, ok := tc_one(t, tc, op)
	if !ok {
		return 0
	}
	id, id_ok := proto.decode_call_id(r.body)
	testing.expect(t, id_ok)
	return id
}

// Our call, from asking for it until it ends. The server says that it rings
// before it answers the request, so this connection must know it is the one
// in the call from its asking.
@(test)
test_call_out :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c
	sounds := &c.voice.notifications

	call_start(c, {name = "alice"})
	r, ok := tc_one(t, &tc, .Call_Start)
	testing.expect(t, ok)
	callee, _ := proto.decode_account_id(r.body)
	testing.expect_value(t, callee, proto.Account_Id(2))
	testing.expect(t, c.call.asking)

	// Only one call at a time, even while the first is being asked for.
	call_start(c, {account = 2})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect_value(t, v.notice.text, "You are already in a call.")

	call_changed(&tc, {id = 7, state = .Ringing, caller = 1, callee = 2})
	testing.expect_value(t, c.call.status, Call_Status.Ringing_Out)
	testing.expect_value(t, c.call.peer, proto.Account_Id(2))
	testing.expect(t, c.call.here)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.Ringback)
	call_id_answer(&tc, r.id, 7)
	testing.expect(t, !c.call.asking)
	testing.expect_value(t, c.call.id, proto.Call_Id(7))
	testing.expect_value(t, v.call.id, proto.Call_Id(7))
	testing.expect_value(t, v.call.status, Call_Status.Ringing_Out)
	testing.expect(t, v.call.here)

	// Answered: the ringback stops.
	call_changed(&tc, {id = 7, state = .Active, caller = 1, callee = 2})
	testing.expect_value(t, c.call.status, Call_Status.Active)
	testing.expect(t, c.call.here)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.None)
	testing.expect_value(t, v.call.status, Call_Status.Active)

	call_hangup(c)
	testing.expect_value(t, sent_call_id(t, &tc, .Call_End), proto.Call_Id(7))
	// The call is only over once the server says so.
	testing.expect_value(t, c.call.status, Call_Status.Active)
	call_changed(&tc, {id = 7, state = .Ended, reason = .Hung_Up, caller = 1, callee = 2})
	testing.expect_value(t, c.call, Call_Client{})
	testing.expect_value(t, v.call.status, Call_Status.None)

	// Now another may be started, and here the answer comes first.
	call_start(c, {account = 2})
	r, _ = tc_one(t, &tc, .Call_Start)
	call_id_answer(&tc, r.id, 8)
	testing.expect_value(t, c.call.id, proto.Call_Id(8))
	testing.expect(t, c.call.here)
	call_changed(&tc, {id = 8, state = .Ringing, caller = 1, callee = 2})
	testing.expect_value(t, c.call.status, Call_Status.Ringing_Out)
	testing.expect(t, c.call.here)

	// Cancelling it while it rings.
	call_hangup(c)
	testing.expect_value(t, sent_call_id(t, &tc, .Call_End), proto.Call_Id(8))

	// Nobody by that name.
	c.call = {}
	call_start(c, {name = "nobody"})
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)
	testing.expect(t, !c.call.asking)
}

// A call that our account started on another device rings out there, not here.
@(test)
test_call_out_elsewhere :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c

	call_changed(&tc, {id = 3, state = .Ringing, caller = 1, callee = 2})
	testing.expect_value(t, c.call.status, Call_Status.Ringing_Out)
	testing.expect(t, !c.call.here)
	testing.expect_value(t, c.voice.notifications.loop_event, audio.Sound_Event.None)
	call_changed(&tc, {id = 3, state = .Active, caller = 1, callee = 2})
	testing.expect_value(t, v.call.status, Call_Status.Active)
	testing.expect(t, !v.call.here)

	// Hanging up from here still ends it.
	call_hangup(c)
	testing.expect_value(t, sent_call_id(t, &tc, .Call_End), proto.Call_Id(3))

	// The end of some other call leaves this one alone.
	call_changed(&tc, {id = 4, state = .Ended, reason = .Hung_Up, caller = 2, callee = 1})
	testing.expect_value(t, c.call.id, proto.Call_Id(3))
	call_changed(&tc, {id = 3, state = .Ended, reason = .Hung_Up, caller = 1, callee = 2})
	testing.expect_value(t, c.call.status, Call_Status.None)
}

@(test)
test_call_start_refused :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c

	refused :: proc(t: ^testing.T, tc: ^Test_Conn, status: proto.Status) {
		call_start(&tc.c, {account = 2})
		r, _ := tc_one(t, tc, .Call_Start)
		tc_answer(tc, r.id, status)
		testing.expect(t, !tc.c.call.asking)
		testing.expect_value(t, tc.c.call.status, Call_Status.None)
	}
	refused(t, &tc, .Closed)
	testing.expect_value(t, v.notice.text, "Alice is not online. They will see a missed call.")
	testing.expect(t, !v.notice.ok)
	refused(t, &tc, .Conflict)
	testing.expect_value(t, v.notice.text, "Alice is already in a call.")
	refused(t, &tc, .Denied)
	testing.expect_value(t, v.notice.text, "The server failed to start the call (Denied).")

	// Lost with the connection: nobody is told, and a call can be started again.
	count := v.notice.count
	call_start(c, {account = 2})
	_, _ = tc_one(t, &tc, .Call_Start)
	tc_restart(&tc)
	testing.expect(t, !c.call.asking)
	testing.expect_value(t, v.notice.count, count)
	call_start(c, {account = 2})
	_, ok := tc_one(t, &tc, .Call_Start)
	testing.expect(t, ok)
}

@(test)
test_call_in :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c
	sounds := &c.voice.notifications

	// Answering is only for a call that rings, and hanging up only for a call.
	call_answer(c)
	call_hangup(c)
	testing.expect_value(t, len(tc_sent(t, &tc)), 0)

	call_ring(&tc, 5, 2)
	testing.expect_value(t, c.call.status, Call_Status.Ringing_In)
	testing.expect_value(t, c.call.peer, proto.Account_Id(2))
	testing.expect(t, !c.call.here)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.Ring)
	testing.expect_value(t, v.call.status, Call_Status.Ringing_In)

	// Answered here: this connection is in the call at once, before the server
	// confirms it.
	call_answer(c)
	testing.expect_value(t, sent_call_id(t, &tc, .Call_Accept), proto.Call_Id(5))
	testing.expect(t, c.call.here)
	testing.expect(t, v.call.here)
	call_changed(&tc, {id = 5, state = .Active, caller = 2, callee = 1})
	testing.expect_value(t, c.call.status, Call_Status.Active)
	testing.expect_value(t, c.call.peer, proto.Account_Id(2))
	testing.expect(t, c.call.here)
	testing.expect_value(t, sounds.loop_event, audio.Sound_Event.None)

	call_changed(&tc, {id = 5, state = .Ended, reason = .Hung_Up, caller = 2, callee = 1})
	testing.expect_value(t, c.call.status, Call_Status.None)

	// Declining one.
	call_ring(&tc, 6, 2)
	call_hangup(c)
	testing.expect_value(t, sent_call_id(t, &tc, .Call_End), proto.Call_Id(6))
}

// Two of our devices answer the same call. The server lets one of them have it.
@(test)
test_call_answered_elsewhere :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c

	call_ring(&tc, 5, 2)
	call_answer(c)
	r, _ := tc_one(t, &tc, .Call_Accept)
	tc_answer(&tc, r.id, .Conflict)
	testing.expect(t, !c.call.here)
	testing.expect(t, !v.call.here)
	testing.expect_value(
		t,
		v.notice.text,
		"The call was already answered on another device, or it has ended.",
	)
	call_changed(&tc, {id = 5, state = .Active, caller = 2, callee = 1})
	testing.expect_value(t, c.call.status, Call_Status.Active)
	testing.expect(t, !c.call.here)

	// A call answered on another device without this one trying is not here
	// either.
	c.call = {}
	call_ring(&tc, 9, 2)
	call_changed(&tc, {id = 9, state = .Active, caller = 2, callee = 1})
	testing.expect_value(t, c.call.status, Call_Status.Active)
	testing.expect(t, !c.call.here)
}

@(test)
test_call_events_and_restart :: proc(t: ^testing.T) {
	tc: Test_Conn
	v := open_caller(&tc)
	defer tc_close(&tc)
	c := &tc.c

	// Garbage changes nothing, and other events are not for calls.
	call_ring(&tc, 5, 2)
	testing.expect(t, calls_event(c, .Call_Ring, []u8{1, 2}))
	testing.expect(t, calls_event(c, .Call_Changed, []u8{1}))
	bad: [proto.CALL_CHANGED_SIZE]u8
	bad[4] = 200 // no such state
	testing.expect(t, calls_event(c, .Call_Changed, bad[:]))
	testing.expect_value(t, c.call.id, proto.Call_Id(5))
	testing.expect_value(t, c.call.status, Call_Status.Ringing_In)
	testing.expect(t, !calls_event(c, .Role_Changed, nil))

	// A new connection is in no call.
	calls_restart(c)
	testing.expect_value(t, c.call, Call_Client{})
	testing.expect_value(t, v.call.status, Call_Status.None)
	testing.expect_value(t, c.voice.notifications.loop_event, audio.Sound_Event.None)
}

@(test)
test_call_system_text :: proc(t: ^testing.T) {
	testing.expect_value(t, call_length(0), "0:00")
	testing.expect_value(t, call_length(65), "1:05")
	testing.expect_value(t, call_length(3599), "59:59")
	testing.expect_value(t, call_length(3600), "1:00:00")
	testing.expect_value(t, call_length(3725), "1:02:05")

	missed := u8(proto.Call_System.Missed)
	declined := u8(proto.Call_System.Declined)
	ended := u8(proto.Call_System.Ended)
	testing.expect_value(t, system_text(missed, 0, "", "Alice", "", false), "Missed call from Alice")
	testing.expect_value(t, system_text(missed, 0, "", "Alice", "", true), "Your call was not answered")
	testing.expect_value(
		t,
		system_text(declined, 0, "", "Alice", "", false),
		"You declined a call from Alice",
	)
	testing.expect_value(t, system_text(declined, 0, "", "Alice", "", true), "Your call was declined")
	testing.expect_value(t, system_text(ended, 125, "", "Alice", "", true), "Call lasted 2:05")
	testing.expect_value(
		t,
		system_text(0, 0, "", "Alice", "", false),
		"(This version cannot display this message)",
	)
}
