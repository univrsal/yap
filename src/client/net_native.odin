#+build !wasi
package client

import "client:conn"
import "core:thread"

// The network loop runs on its own thread, so a slow frame never
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
	conn.net_run(
		ns.client,
		{
			key_path = ns.key_path,
			server = ns.server,
			password = ns.password,
			known_servers = ns.known_servers,
			channel = ns.channel,
			look_at = ns.look_at,
		},
		&ns.stop,
	)
}
