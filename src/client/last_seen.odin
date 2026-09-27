package client

import log "../common/wlog"

import "../proto"

/*
When users were last on the server (src/proto/last_seen.odin), for the
buddy screen to say about those who aren't here. The UI asks
(Last_Seen_Command), the network loop passes the question on, and the
answer goes to the View.
*/

Last_Seen_Command :: struct {
	keys:  [proto.MAX_LAST_SEEN][proto.KEY_SIZE]u8,
	count: int,
}

last_seen_ask :: proc(c: ^Voice_Client, cmd: Last_Seen_Command) {
	cmd := cmd
	if !c.has_current || cmd.count == 0 {
		return
	}
	out: [proto.MAX_PAYLOAD_SIZE]u8
	send_data(c, proto.encode_last_seen_get(out[:], cmd.keys[:cmd.count]))
}

handle_last_seen :: proc(c: ^Voice_Client, pt: []u8) {
	for i in 0 ..< proto.last_seen_count(pt) {
		key, seen := proto.last_seen_entry(pt, i)
		publish_last_seen(c, key, seen)
		if c.view == nil {
			// Headless (/seen): the log is the only place to show it.
			switch seen {
			case 0:
				log.infof("[seen] %s: never on this server", fingerprint(key))
			case proto.LAST_SEEN_HIDDEN:
				log.infof("[seen] %s: not shared (you haven't both sent each other DMs)", fingerprint(key))
			case:
				log.infof("[seen] %s: last here at unix time %d", fingerprint(key), seen)
			}
		}
	}
}
