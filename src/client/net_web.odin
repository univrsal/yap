#+build wasi
package client

import "core:sync"

/*
A browser build has no threads, so the network loop doesn't get one: it
is stepped from the frame loop instead (see ui_frame), a few turns at a
time so a frame's worth of packets is handled without the loop running
away with the frame.
*/
Net_Thread :: struct {}

// How many turns of the network loop to take per frame. Each one
// handles at most one packet, and at sixty frames a second this keeps
// up with far more than a channel can produce.
NET_STEPS_PER_FRAME :: 8

net_start :: proc(ns: ^Net_Session) {
	c := ns.client
	if !client_open(c, ns.key_path, ns.server, ns.known_servers, ns.name, ns.password) {
		ns.stopped = true
		return
	}
	if ns.channel != "" {
		request_join(c, ns.channel)
	}
}

net_stop :: proc(ns: ^Net_Session) {
	if !ns.stopped {
		ns.stopped = true
		client_close(ns.client)
	}
}

// net_step gives the connection its turn between frames.
net_step :: proc(ui: ^UI) {
	ns := ui.session
	if ns == nil || ns.stopped || sync.atomic_load(&ns.stop) {
		return
	}
	for _ in 0 ..< NET_STEPS_PER_FRAME {
		if !client_step(ns.client) {
			ns.stopped = true
			client_close(ns.client)
			return
		}
	}
}
