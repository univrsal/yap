package proto

/*
Web Push (src/server/push.odin, misc/mobile): a browser that has turned
push on gives the server its subscription, so the server can tell it
about messages while the client isn't open.

	Push_Subscribe    request   [endpoint str16][p256dh 65][auth 16]
	                  response  (nothing)
	Push_Unsubscribe  request   (nothing)
	                  response  (nothing)

A subscription is the endpoint URL at the browser's push service and
its two keys, as PushSubscription gives them: p256dh, an uncompressed
P-256 point, and the auth secret. The browser subscribes with the
server's VAPID key, Server_Info's push_key; a server that gives none
doesn't push, and answers Push_Subscribe Closed.

A subscription is this device's (the connection's key): one each, a new
one taking the place of the last, and gone with the device when it logs
out or is revoked. Push_Unsubscribe forgets this device's.
*/

// What a P-256 public key (p256dh, and the VAPID key) takes, and an auth
// secret.
PUSH_KEY_SIZE :: 65
PUSH_AUTH_SIZE :: 16
// The longest endpoint URL taken. Push services' are well under 1 KB.
MAX_PUSH_ENDPOINT :: 2048

Push_Subscription :: struct {
	endpoint: string,
	p256dh:   [PUSH_KEY_SIZE]u8,
	auth:     [PUSH_AUTH_SIZE]u8,
}

PUSH_SUBSCRIBE_MAX_SIZE :: 2 + MAX_PUSH_ENDPOINT + PUSH_KEY_SIZE + PUSH_AUTH_SIZE

@(require_results)
encode_push_subscribe :: proc(out: []u8, sub: Push_Subscription) -> (body: []u8, ok: bool) {
	if len(sub.endpoint) == 0 || len(sub.endpoint) > MAX_PUSH_ENDPOINT {
		return
	}
	sub := sub
	w := Writer {
		buf = out,
	}
	put_str16(&w, sub.endpoint)
	put_bytes(&w, sub.p256dh[:])
	put_bytes(&w, sub.auth[:])
	if w.overflow {
		return
	}
	return out[:w.pos], true
}

// decode_push_subscribe reads one; the endpoint points into `body`, and
// is to be checked before it's used.
@(require_results)
decode_push_subscribe :: proc(body: []u8) -> (sub: Push_Subscription, ok: bool) {
	r := Reader {
		buf = body,
	}
	sub.endpoint = get_str16(&r)
	copy(sub.p256dh[:], get_bytes(&r, PUSH_KEY_SIZE))
	copy(sub.auth[:], get_bytes(&r, PUSH_AUTH_SIZE))
	if r.overflow || len(sub.endpoint) == 0 || len(sub.endpoint) > MAX_PUSH_ENDPOINT {
		return {}, false
	}
	return sub, true
}
