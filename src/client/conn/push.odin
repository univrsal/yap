package conn

import "core:fmt"

import "common:proto"

/*
Web Push (src/common/proto/push.odin): giving the server this browser's
subscription, or taking it back. The subscribing itself is the
browser's, done by the UI (src/client/ui_push_web.odin, web/push.js);
this only tells the server. A server that pushes says so with its key
(Server_Details.push_key, View.server_push_key).
*/

// This device's subscription, to give the server; the endpoint is owned.
Push_Subscribe_Command :: struct {
	sub: proto.Push_Subscription,
}
// Forget this device's subscription.
Push_Unsubscribe_Command :: struct {}

push_subscribe :: proc(c: ^Voice_Client, sub: proto.Push_Subscription) {
	buf: [proto.PUSH_SUBSCRIBE_MAX_SIZE]u8
	body, ok := proto.encode_push_subscribe(buf[:], sub)
	if !ok {
		return
	}
	request(c, .Push_Subscribe, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		if status != .Ok && status != .Reset {
			notify(c, false, fmt.tprintf("The server wouldn't take push notifications (%v).", status))
		}
	})
}

push_unsubscribe :: proc(c: ^Voice_Client) {
	request(c, .Push_Unsubscribe, nil, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {})
}
