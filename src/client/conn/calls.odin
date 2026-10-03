package conn

import log "common:wlog"
import "core:fmt"
import "core:time"

import "common:proto"
import "client:audio"

/*
Calls on our end (src/common/proto/calls.odin): the one call our account
is in, if any, as the server tells it, and asking to start, answer and
end it. While one rings in, the ring plays; while ours rings out, the
ringback. Our connection is in the call if it started it or answered it;
the account's others only show that there is one.
*/

Call_Status :: enum {
	None,
	Ringing_In, // somebody is calling us
	Ringing_Out, // we're calling somebody
	Active,
}

Call_Client :: struct {
	id:       proto.Call_Id,
	status:   Call_Status,
	peer:     proto.Account_Id, // whom it's with
	// This connection started it, or answered it: it's the one in it.
	here:     bool,
	asking:   bool, // a Call_Start is out
	since:    time.Tick, // when it started ringing, or was answered
}

// Call somebody; headless, by name.
Call_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
}
// Answer the call ringing in, on this connection.
Call_Answer_Command :: struct {}
// Hang up, cancel, or decline: whichever the call is.
Call_Hangup_Command :: struct {}

// The call as the UI shows it.
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
		notify(c, false, "You're in a call already.")
		return
	}
	cc.asking = true
	buf: [4]u8
	request(c, .Call_Start, proto.encode_account_id(&buf, account), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		cc := &c.call
		cc.asking = false
		#partial switch status {
		case .Ok:
			id, _ := proto.decode_call_id(body)
			// Ours, from here: told of it as it changes (Call_Changed).
			if cc.id == 0 || cc.id == id {
				cc.id = id
				cc.here = true
				publish_call(c)
			}
			call_sounds(c)
		case .Closed:
			notify(c, false, fmt.tprintf("%s isn't here; they'll see a missed call.", account_display(c, proto.Account_Id(tag))))
		case .Conflict:
			notify(c, false, fmt.tprintf("%s is in a call.", account_display(c, proto.Account_Id(tag))))
		case .Reset:
		case:
			notify(c, false, fmt.tprintf("The call couldn't be made (%v).", status))
		}
	}, u64(account))
}

call_answer :: proc(c: ^Voice_Client) {
	cc := &c.call
	if cc.status != .Ringing_In {
		return
	}
	cc.here = true
	buf: [4]u8
	request(c, .Call_Accept, proto.encode_call_id(&buf, cc.id), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		if status != .Ok && status != .Reset {
			c.call.here = false
			notify(c, false, "That call was answered elsewhere, or is over.")
			publish_call(c)
		}
	})
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

// calls_event takes an event about calls; false if `op` isn't one.
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
				log.infof("[call] in a call with %s%s", account_display(c, peer), "" if here else " (on another device)")
			}
		case .Ended:
			if cc.id == change.id {
				cc^ = {}
			}
			if c.view == nil {
				log.infof("[call] the call with %s is over (%v)", account_display(c, peer), change.reason)
			}
		}
	case:
		return false
	}
	call_sounds(c)
	publish_call(c)
	return true
}

// calls_restart: a new connection is in no call, whatever the server
// had of the old one.
calls_restart :: proc(c: ^Voice_Client) {
	c.call = {}
	call_sounds(c)
	publish_call(c)
}

// call_sounds plays what the call's state calls for: the ring while one
// rings in, the ringback while ours rings out, else nothing.
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

/*
system_text is what a system message says: for a call (proto.Call_System),
from the caller (`sender`, called `name`; `mine` if that's us), whether it
was missed, declined, or how long it was. In the temp allocator.
*/
system_text :: proc(what: u8, arg: u32, name: string, mine: bool) -> string {
	switch proto.Call_System(what) {
	case .Missed:
		return "Missed call (not answered)" if mine else fmt.tprintf("Missed call from %s", name)
	case .Declined:
		return "Call declined" if mine else fmt.tprintf("Call from %s, declined", name)
	case .Ended:
		return fmt.tprintf("Call, %s", call_length(int(arg)))
	}
	return "(something happened that this version can't say)"
}

// call_length is a call's length as it's read: 1:05, or 1:02:05.
call_length :: proc(seconds: int) -> string {
	if seconds >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
	}
	return fmt.tprintf("%d:%02d", seconds / 60, seconds % 60)
}
