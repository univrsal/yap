#+build !wasi
package client

import "core:sync"
import "core:thread"

// The network loop runs on a thread of its own, so a slow frame never
// holds up the voice and a slow network never holds up the window.
Net_Thread :: ^thread.Thread

net_start :: proc(ns: ^Net_Session) {
	ns.thread = thread.create_and_start_with_poly_data(ns, net_thread, init_context = context)
}

net_stop :: proc(ns: ^Net_Session) {
	thread.join(ns.thread)
	thread.destroy(ns.thread)
}

@(private = "file")
net_thread :: proc(ns: ^Net_Session) {
	c := ns.client
	defer client_close(c)
	if !client_open(c, ns.key_path, ns.server, ns.known_servers, ns.name) {
		return
	}
	if ns.channel != "" {
		request_join(c, ns.channel)
	}
	for !sync.atomic_load(&ns.stop) {
		if !client_step(c) {
			return
		}
	}
}
