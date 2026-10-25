package proto

// Web Push (src/server/webpush/webpush.odin, docs/design/mobile.md): a browser that has enabled push sends its
// subscription to the server, so the server can notify it about messages while the client
// isn't open.
//
//	Push_Subscribe    request   [endpoint str16][p256dh 65][auth 16]
//	                  response  (nothing)
//	Push_Unsubscribe  request   (nothing)
//	                  response  (nothing)
//
// A subscription consists of the endpoint URL at the browser's push service and the two
// keys that PushSubscription provides: p256dh, an uncompressed P-256 point, and the auth
// secret. The browser subscribes using the server's VAPID key (Server_Info's push_key); a
// server that doesn't advertise a key doesn't support push and answers Push_Subscribe with
// Closed.
//
// A subscription belongs to a device (identified by the connection's key). Each device has
// at most one: a new subscription replaces the previous one, and it is deleted along with
// the device when the device logs out or is revoked. Push_Unsubscribe deletes this
// device's subscription.

// The size of an uncompressed P-256 public key (p256dh and the VAPID key), and of an auth
// secret.
PUSH_KEY_SIZE :: 65
PUSH_AUTH_SIZE :: 16
// The longest accepted endpoint URL. Push services use URLs well under 1 KB.
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

// decode_push_subscribe decodes a Push_Subscribe request. The endpoint points into `body`
// and must be validated before it is used.
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
