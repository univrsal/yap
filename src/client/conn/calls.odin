package conn

import log "common:wlog"
import "core:fmt"
import "core:time"

import "client:audio"
import "common:proto"

// This file handles calls on our end (src/common/proto/calls.odin). It tracks
// the one call our account is in (if any) as reported by the server, and
// sends requests to start, answer and end it. The ring plays while a call
// rings in, and the ringback plays while our call rings out. This connection
// is part of the call if it started or answered it. The account's other
// connections only show that a call exists.

Call_Status :: enum {
	None,
	Ringing_In, // somebody is calling us
	Ringing_Out, // we're calling somebody
	Active,
}

Call_Client :: struct {
	id:     proto.Call_Id,
	status: Call_Status,
	peer:   proto.Account_Id, // the other participant
	// True if this connection started or answered the call and is thus the one in it.
	here:   bool,
	asking: bool, // a Call_Start request is pending
	since:  time.Tick, // when the call started ringing or was answered
}

// Calls somebody, by name (headless).
Call_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
}
// Answers the incoming call on this connection.
Call_Answer_Command :: struct {}
// Hangs up, cancels or declines the call, depending on its state.
Call_Hangup_Command :: struct {}

// The call as shown by the UI.
View_Call :: struct {
	id:     proto.Call_Id,
	status: Call_Status,
	peer:   proto.Account_Id,
	here:   bool,
	since:  time.Tick,
}

call_start :: proc(c: ^Voice_Client, cmd: Call_Command) {
	cc := &c.call
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	switch {
	case account == 0:
		log.warn("there's no such account")
		return
	case cc.status != .None || cc.asking:
		notify(c, false, "You are already in a call.")
		return
	}
	cc.asking = true
	buf: [4]u8
	request(
		c,
		.Call_Start,
		proto.encode_account_id(&buf, account),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			cc := &c.call
			cc.asking = false
			#partial switch status {
			case .Ok:
				id, _ := proto.decode_call_id(body)
				// The call is ours, and we are told about changes to it (Call_Changed).
				if cc.id == 0 || cc.id == id {
					cc.id = id
					cc.here = true
					publish_call(c)
				}
				call_sounds(c)
			case .Closed:
				notify(
					c,
					false,
					fmt.tprintf(
						"%s is not online. They will see a missed call.",
						account_display(c, proto.Account_Id(tag)),
					),
				)
			case .Conflict:
				notify(
					c,
					false,
					fmt.tprintf(
						"%s is already in a call.",
						account_display(c, proto.Account_Id(tag)),
					),
				)
			case .Reset:
			case:
				notify(c, false, fmt.tprintf("The server failed to start the call (%v).", status))
			}
		},
		u64(account),
	)
}

call_answer :: proc(c: ^Voice_Client) {
	cc := &c.call
	if cc.status != .Ringing_In {
		return
	}
	cc.here = true
	buf: [4]u8
	request(
		c,
		.Call_Accept,
		proto.encode_call_id(&buf, cc.id),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				c.call.here = false
				notify(
					c,
					false,
					"The call was already answered on another device, or it has ended.",
				)
				publish_call(c)
			}
		},
	)
	publish_call(c)
}

call_hangup :: proc(c: ^Voice_Client) {
	cc := &c.call
	if cc.status == .None {
		return
	}
	buf: [4]u8
	request(c, .Call_End, proto.encode_call_id(&buf, cc.id), nil)
}

// calls_event handles an event about calls. It returns false if `op` is not a
// call event.
calls_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
	cc := &c.call
	#partial switch op {
	case .Call_Ring:
		id, from, ok := proto.decode_call_ring(body)
		if !ok {
			return true
		}
		cc^ = {
			id     = id,
			status = .Ringing_In,
			peer   = from,
			since  = time.tick_now(),
		}
		if c.view == nil {
			log.infof("[call] %s is calling (/answer, /hangup)", account_display(c, from))
		}
	case .Call_Changed:
		change, ok := proto.decode_call_changed(body)
		if !ok {
			return true
		}
		me := c.auth.me
		peer := change.callee if change.caller == me else change.caller
		switch change.state {
		case .Ringing:
			if change.caller == me {
				was_here := cc.here && cc.id == change.id
				cc^ = {
					id     = change.id,
					status = .Ringing_Out,
					peer   = peer,
					here   = was_here || (cc.asking && cc.id == 0),
					since  = time.tick_now(),
				}
				if c.view == nil {
					log.infof("[call] calling %s", account_display(c, peer))
				}
			}
		case .Active:
			here := cc.here && cc.id == change.id
			cc^ = {
				id     = change.id,
				status = .Active,
				peer   = peer,
				here   = here,
				since  = time.tick_now(),
			}
			if c.view == nil {
				log.infof(
					"[call] in a call with %s%s",
					account_display(c, peer),
					"" if here else " (on another device)",
				)
			}
		case .Ended:
			if cc.id == change.id {
				cc^ = {}
			}
			if c.view == nil {
				log.infof(
					"[call] the call with %s is over (%v)",
					account_display(c, peer),
					change.reason,
				)
			}
		}
	case:
		return false
	}
	call_sounds(c)
	publish_call(c)
	return true
}

// calls_restart resets the call state. A new connection is not in any call,
// regardless of what the server knew about the old connection.
calls_restart :: proc(c: ^Voice_Client) {
	c.call = {}
	call_sounds(c)
	publish_call(c)
}

// call_sounds plays the sound that fits the call's state: the ring while a call
// rings in, the ringback while our call rings out, and nothing otherwise.
@(private = "file")
call_sounds :: proc(c: ^Voice_Client) {
	loop: audio.Loop_Kind
	#partial switch c.call.status {
	case .Ringing_In:
		loop = .Ring
	case .Ringing_Out:
		if c.call.here {
			loop = .Ringback
		}
	}
	audio.notification_loop(&c.voice.notifications, loop)
}

@(private = "file")
publish_call :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	cc := &c.call
	view_write(v)
	v.call = {
		id     = cc.id,
		status = cc.status,
		peer   = cc.peer,
		here   = cc.here,
		since  = cc.since,
	}
}

// system_text returns the text of a call system message (proto.Call_System),
// which says whether the call was missed, declined, or how long it lasted.
// `name` is the caller's name and `mine` is true if we are the caller. The
// result is allocated in the temp allocator.
system_text :: proc(what: u8, arg: u32, name: string, mine: bool) -> string {
	switch proto.Call_System(what) {
	case .Missed:
		return "Your call was not answered" if mine else fmt.tprintf("Missed call from %s", name)
	case .Declined:
		return(
			"Your call was declined" if mine else fmt.tprintf("You declined a call from %s", name) \
		)
	case .Ended:
		return fmt.tprintf("Call lasted %s", call_length(int(arg)))
	}
	return "(This version cannot display this message)"
}

// call_length formats a call's duration as 1:05 or 1:02:05.
call_length :: proc(seconds: int) -> string {
	if seconds >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
	}
	return fmt.tprintf("%d:%02d", seconds / 60, seconds % 60)
}
