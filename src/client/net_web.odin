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
	} else if ns.view != "" {
		conn.conv_start_viewing(c, ns.view)
	}
}

net_stop :: proc(ns: ^Net_Session) {
	if !ns.stopped {
		ns.stopped = true
		conn.client_close(ns.client)
	}
}

// net_step gives the connection its turn between frames.
net_step :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil || ns.stopped || sync.atomic_load(&ns.stop) {
		return
	}
	start := time.tick_now()
	for i := 0;; i += 1 {
		if !conn.client_step(ns.client) {
			ns.stopped = true
			conn.client_close(ns.client)
			return
		}
		if i + 1 >= NET_STEPS_PER_FRAME &&
		   (!conn.transport_pending(&ns.client.transport) ||
				   time.tick_since(start) >= NET_FRAME_BUDGET) {
			return
		}
	}
}
