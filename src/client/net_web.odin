#+build wasi
package client

import "client:conn"
import "core:sync"
import "core:time"

/*
A browser build has no threads, so the network loop doesn't get one: it
is stepped from the frame loop instead (see ui_frame), a few turns at a
time so a frame's worth of packets is handled without the loop running
away with the frame.
*/
Net_Thread :: struct {}

// Each turn of the network loop handles at most one packet. A frame
// takes at least NET_STEPS_PER_FRAME turns, which keeps up with any
// amount of voice, and then more while packets are waiting - a
// keyframe of shared screen is a hundred or more at once - for up to
// NET_FRAME_BUDGET.
NET_STEPS_PER_FRAME :: 8
NET_FRAME_BUDGET :: 4 * time.Millisecond

net_start :: proc(ns: ^Net_Session) {
	c := ns.client
	if !conn.client_open(c, ns.key_path, ns.server, ns.known_servers, ns.password) {
		ns.stopped = true
		return
	}
	if ns.channel != "" {
		conn.conv_start_in(c, ns.channel)
	} else if ns.look_at != "" {
		conn.conv_start_viewing(c, ns.look_at)
	}
}

net_stop :: proc(ns: ^Net_Session) {
	if !ns.stopped {
		ns.stopped = true
		conn.client_close(ns.client)
	}
}

// net_step gives every connection its turn between frames: the frame's
// network budget goes round them, the shown one first.
net_step :: proc(ui: ^UI) {
	start := time.tick_now()
	if ui.session != nil {
		session_step(ui.session, start)
	}
	for ns in ui.sessions {
		if ns != ui.session {
			session_step(ns, start)
		}
	}
}

@(private = "file")
session_step :: proc(ns: ^Net_Session, start: time.Tick) {
	if ns.stopped || sync.atomic_load(&ns.stop) {
		return
	}
	for i := 0;; i += 1 {
		if !conn.client_step(ns.client) {
			ns.stopped = true
			conn.client_close(ns.client)
			return
		}
		c := ns.client
		waiting :=
			conn.transport_pending(&c.transport) || conn.transport_pending(&c.bulk.transport)
		if i + 1 >= NET_STEPS_PER_FRAME &&
		   (!waiting || time.tick_since(start) >= NET_FRAME_BUDGET) {
			return
		}
	}
}
