package server

import "core:log"
import "core:time"

import "common:proto"

/*
Calls (src/common/proto/calls.odin): two accounts talking outside any
channel. A call lives only here, in memory; what's left of one is the
system message it leaves in the two accounts' DM (a missed call, a
declined one, or how long it lasted).

A call rings on every connection of the callee until one answers (and
is put in the call's room with the caller's connection that called), or
the caller cancels, the callee declines, or CALL_RING_SECONDS pass. Once
on, it ends when either hangs up, or either connection leaves the room:
for a channel's (conn_set_room), or by going (calls_conn_gone).

An account is in at most one call at a time, calling or called.
*/

Call :: struct {
	id:          proto.Call_Id,
	caller:      proto.Account_Id,
	callee:      proto.Account_Id,
	state:       proto.Call_State,
	rang:        time.Tick, // when it started ringing
	answered:    time.Tick, // when it was answered
	// The connections in it: the caller's that called, and once it's
	// answered, the callee's that answered.
	caller_conn: ^Conn,
	callee_conn: ^Conn,
}

Calls :: struct {
	by_id: map[proto.Call_Id]^Call,
	last:  proto.Call_Id,
}

calls_destroy :: proc(s: ^Server) {
	for _, call in s.calls.by_id {
		free(call)
	}
	delete(s.calls.by_id)
	s.calls = {}
}

// call_of is the call an account is in, calling or called; nil if none.
call_of :: proc(s: ^Server, account: proto.Account_Id) -> ^Call {
	for _, call in s.calls.by_id {
		if call.caller == account || call.callee == account {
			return call
		}
	}
	return nil
}

// call_request handles a request about calls; false if `op` isn't one.
call_request :: proc(s: ^Server, u: ^Conn, id: u32, op: proto.Request_Op, body: []u8) -> bool {
	#partial switch op {
	case .Call_Start:
		call_start(s, u, id, body)
	case .Call_Accept:
		call_accept_request(s, u, id, body)
	case .Call_End:
		call_end_request(s, u, id, body)
	case:
		return false
	}
	return true
}

@(private = "file")
call_start :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	callee_id, ok := proto.decode_account_id(body)
	me := u.account.id
	callee := account_by_id(&s.accounts, callee_id)
	switch {
	case !ok || callee_id == me:
		respond(u, id, .Invalid)
		return
	case callee == nil:
		respond(u, id, .Not_Found)
		return
	}
	// Both calling each other at once: this is the answer to theirs.
	if theirs := call_of(s, me); theirs != nil && theirs.state == .Ringing && theirs.caller == callee_id && theirs.callee == me {
		buf: [4]u8
		respond(u, id, .Ok, proto.encode_call_id(&buf, theirs.id))
		call_accept(s, theirs, u)
		return
	}
	switch {
	case call_of(s, me) != nil || call_of(s, callee_id) != nil:
		respond(u, id, .Conflict)
		return
	case len(callee.conns) == 0:
		// Nobody to ring: a missed call, for when they're back.
		respond(u, id, .Closed)
		call_note(s, me, callee_id, .Missed, 0)
		return
	}
	s.calls.last += 1
	call := new(Call)
	call^ = {
		id          = s.calls.last,
		caller      = me,
		callee      = callee_id,
		state       = .Ringing,
		rang        = time.tick_now(),
		caller_conn = u,
	}
	s.calls.by_id[call.id] = call
	log.infof("%s is calling %s", conn_label(u), callee.username)
	buf: [4]u8
	respond(u, id, .Ok, proto.encode_call_id(&buf, call.id))
	ring_buf: [proto.CALL_RING_SIZE]u8
	ring := proto.encode_call_ring(&ring_buf, call.id, me)
	for c in callee.conns {
		send_event(c, .Call_Ring, ring)
	}
	call_tell(s, call, .None)
}

@(private = "file")
call_accept_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	call_id, ok := proto.decode_call_id(body)
	call := s.calls.by_id[call_id] or_else nil
	switch {
	case !ok:
		respond(u, id, .Invalid)
		return
	case call == nil || call.callee != u.account.id:
		respond(u, id, .Not_Found)
		return
	case call.state != .Ringing:
		// Answered already, on another device.
		respond(u, id, .Conflict)
		return
	}
	respond(u, id, .Ok)
	call_accept(s, call, u)
}

// call_accept puts the call on: the callee's connection that answered,
// and the caller's that called, are in its room, out of any other.
@(private = "file")
call_accept :: proc(s: ^Server, call: ^Call, u: ^Conn) {
	call.state = .Active
	call.answered = time.tick_now()
	call.callee_conn = u
	log.infof("%s answered call %d", conn_label(u), call.id)
	room := proto.call_room(call.id)
	for c in ([]^Conn{call.caller_conn, call.callee_conn}) {
		// One connection of an account talks at a time.
		for other in c.account.conns {
			if other != c && other.room != 0 {
				conn_set_room(s, other, 0)
				buf: [4]u8
				send_event(other, .Voice_Moved, proto.encode_room(&buf, room))
			}
		}
		conn_set_room(s, c, room)
	}
	call_tell(s, call, .None)
}

@(private = "file")
call_end_request :: proc(s: ^Server, u: ^Conn, id: u32, body: []u8) {
	call_id, ok := proto.decode_call_id(body)
	call := s.calls.by_id[call_id] or_else nil
	me := u.account.id
	switch {
	case !ok:
		respond(u, id, .Invalid)
		return
	case call == nil || (call.caller != me && call.callee != me):
		respond(u, id, .Not_Found)
		return
	}
	respond(u, id, .Ok)
	reason := proto.Call_End_Reason.Hung_Up
	if call.state == .Ringing {
		reason = .Cancelled if me == call.caller else .Declined
	}
	call_end(s, call, reason)
}

/*
call_end ends a call: out of the table, both connections out of its room,
both accounts told, and the line it leaves in their DM.
*/
call_end :: proc(s: ^Server, call: ^Call, reason: proto.Call_End_Reason) {
	delete_key(&s.calls.by_id, call.id)
	defer free(call)
	call.state = .Ended
	room := proto.call_room(call.id)
	for c in ([]^Conn{call.caller_conn, call.callee_conn}) {
		if c != nil && c.account != nil && c.room == room {
			conn_set_room(s, c, 0)
		}
	}
	call_tell(s, call, reason)
	seconds := 0
	if call.answered != {} {
		seconds = int(time.duration_seconds(time.tick_since(call.answered)))
	}
	log.infof("call %d ended: %v%s", call.id, reason, "" if call.answered == {} else "")
	#partial switch reason {
	case .Declined:
		call_note(s, call.caller, call.callee, .Declined, 0)
	case .Cancelled, .Unanswered:
		call_note(s, call.caller, call.callee, .Missed, 0)
	case:
		if call.answered != {} {
			call_note(s, call.caller, call.callee, .Ended, seconds)
		} else {
			call_note(s, call.caller, call.callee, .Missed, 0)
		}
	}
}

// call_tell tells every connection of both accounts how a call is now.
@(private = "file")
call_tell :: proc(s: ^Server, call: ^Call, reason: proto.Call_End_Reason) {
	buf: [proto.CALL_CHANGED_SIZE]u8
	body := proto.encode_call_changed(
		&buf,
		{id = call.id, state = call.state, reason = reason, caller = call.caller, callee = call.callee},
	)
	for account in ([]proto.Account_Id{call.caller, call.callee}) {
		if acc := account_by_id(&s.accounts, account); acc != nil {
			for c in acc.conns {
				send_event(c, .Call_Changed, body)
			}
		}
	}
}

/*
call_note leaves a call's line in the two accounts' DM, from the caller:
a system message, which counts as unread like any other.
*/
@(private = "file")
call_note :: proc(s: ^Server, caller, callee: proto.Account_Id, what: proto.Call_System, seconds: int) {
	conv := dm_find(&s.convs, caller, callee)
	if conv == nil {
		conv = dm_add(&s.convs, caller, callee, caller)
		if conv == nil {
			log.error("could not make a DM for a call's message")
			return
		}
	}
	first := conv.last_msg == 0
	m := proto.Message {
		conv       = conv.id,
		sender     = caller,
		kind       = .System,
		system     = u8(what),
		system_arg = u32(max(seconds, 0)),
	}
	if !msg_store(s, conv, &m, 0) {
		log.error("could not keep a call's message")
		return
	}
	if first {
		// News to both, as a DM's first message is: told of the
		// conversation as it was before it, so it counts as unread.
		last := conv.last_msg
		conv.last_msg = 0
		send_conv_to_account(s, callee, conv)
		send_conv_to_account(s, caller, conv)
		conv.last_msg = last
	}
	msg_deliver(s, conv, m)
}

// calls_sync ends the calls that have rung for too long. Every turn of
// the loop.
calls_sync :: proc(s: ^Server) {
	if len(s.calls.by_id) == 0 {
		return
	}
	unanswered := make([dynamic]^Call, context.temp_allocator)
	for _, call in s.calls.by_id {
		if call.state == .Ringing && time.tick_since(call.rang) >= proto.CALL_RING_SECONDS * time.Second {
			append(&unanswered, call)
		}
	}
	for call in unanswered {
		call_end(s, call, .Unanswered)
	}
}

/*
calls_room_left: a connection is leaving a call's room for another (or
none), so the call is over; or it was ringing out, and it's going
elsewhere. Called by conn_set_room before the move.
*/
calls_room_left :: proc(s: ^Server, u: ^Conn, to: proto.Room) {
	if id := proto.room_call(u.room); id != 0 && proto.room_call(to) != id {
		if call := s.calls.by_id[id] or_else nil; call != nil {
			call_end(s, call, .Left)
		}
	}
}

// calls_conn_gone: a connection has gone (or logged out). A call it was
// in, or was ringing out from, is over.
calls_conn_gone :: proc(s: ^Server, u: ^Conn) {
	for _, call in s.calls.by_id {
		if call.caller_conn == u || call.callee_conn == u {
			call_end(s, call, .Cancelled if call.state == .Ringing else .Left)
			return
		}
	}
}

// call_room_member is whether an account may know who is in a call's
// room: one of its two.
call_room_member :: proc(s: ^Server, room: proto.Room, account: proto.Account_Id) -> bool {
	call := s.calls.by_id[proto.room_call(room)] or_else nil
	return call != nil && (call.caller == account || call.callee == account)
}
