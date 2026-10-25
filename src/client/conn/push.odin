package conn

import "core:fmt"

import "common:proto"

// Web Push (src/common/proto/push.odin): sends this browser's push subscription to the
// server, or withdraws it. The browser itself creates the subscription, started by the UI
// (src/client/ui_push_web.odin, web/push.js); this file only informs the server. A server
// that supports push advertises its VAPID key (Server_Details.push_key, View.server_push_key).

// Sends this device's subscription to the server. The endpoint string is owned.
Push_Subscribe_Command :: struct {
	sub: proto.Push_Subscription,
}
// Asks the server to forget this device's subscription.
Push_Unsubscribe_Command :: struct {}

push_subscribe :: proc(c: ^Server_Conn, sub: proto.Push_Subscription) {
	buf: [proto.PUSH_SUBSCRIBE_MAX_SIZE]u8
	body, ok := proto.encode_push_subscribe(buf[:], sub)
	if !ok {
		return
	}
	request(
		c,
		.Push_Subscribe,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				notify(
					c,
					false,
					fmt.tprintf(
						"The server failed to enable push notifications for this device (%v).",
						status,
					),
				)
			}
		},
	)
}

push_unsubscribe :: proc(c: ^Server_Conn) {
	request(
		c,
		.Push_Unsubscribe,
		nil,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {},
	)
}
