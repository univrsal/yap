package server

import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests for the Web Push cryptography (push_crypto.odin), using the example from RFC 8291.

@(test)
test_push_encrypt_rfc8291 :: proc(t: ^testing.T) {
	// RFC 8291, appendix A.
	as_private, _ := base64url_decode(
		"yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
		context.temp_allocator,
	)
	ua_public, _ := base64url_decode(
		"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
		context.temp_allocator,
	)
	salt, _ := base64url_decode("DGv6ra1nlYgDCS1FRnbzlw", context.temp_allocator)
	auth, _ := base64url_decode("BTBZMqHH6r4Tts7J_aSIgg", context.temp_allocator)
	want := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_set_bytes(&key, .SECP256R1, as_private))
	plaintext := "When I grow up, I want to be a watermelon"
	body, ok := push_encrypt_with(
		transmute([]u8)plaintext,
		ua_public,
		auth,
		&key,
		salt,
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, base64url(body, context.temp_allocator), want)

	// Every call uses a fresh key and salt.
	a, a_ok := push_encrypt(transmute([]u8)plaintext, ua_public, auth, context.temp_allocator)
	b, b_ok := push_encrypt(transmute([]u8)plaintext, ua_public, auth, context.temp_allocator)
	testing.expect(t, a_ok && b_ok)
	testing.expect_value(t, len(a), len(body))
	testing.expect(t, string(a) != string(b))

	// An invalid p256dh point, or a payload that is too large.
	bad := make([]u8, P256_PUBLIC_SIZE, context.temp_allocator)
	bad[0] = 4
	_, bad_ok := push_encrypt(transmute([]u8)plaintext, bad, auth, context.temp_allocator)
	testing.expect(t, !bad_ok)
	big := make([]u8, PUSH_PAYLOAD_MOST + 1, context.temp_allocator)
	_, big_ok := push_encrypt(big, ua_public, auth, context.temp_allocator)
	testing.expect(t, !big_ok)
	most, most_ok := push_encrypt(big[:PUSH_PAYLOAD_MOST], ua_public, auth, context.temp_allocator)
	testing.expect(t, most_ok)
	testing.expect_value(t, len(most), 4096)
}

@(test)
test_vapid_jwt :: proc(t: ^testing.T) {
	encoded, ok := vapid_key_generate(context.temp_allocator)
	testing.expect(t, ok)
	key: ecdsa.Private_Key
	testing.expect(t, vapid_key_parse(encoded, &key))
	testing.expect(t, !vapid_key_parse("abcd", &key))
	testing.expect(t, vapid_key_parse(encoded, &key))

	jwt := vapid_jwt(
		&key,
		"https://push.example.net",
		"mailto:admin@example.org",
		1700000000,
		context.temp_allocator,
	)
	parts := strings.split(jwt, ".", context.temp_allocator)
	testing.expect_value(t, len(parts), 3)
	header, _ := base64url_decode(parts[0], context.temp_allocator)
	testing.expect_value(t, string(header), `{"typ":"JWT","alg":"ES256"}`)
	claims, _ := base64url_decode(parts[1], context.temp_allocator)
	testing.expect_value(
		t,
		string(claims),
		`{"aud":"https://push.example.net","exp":1700000000,"sub":"mailto:admin@example.org"}`,
	)

	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, &key)
	sig, _ := base64url_decode(parts[2], context.temp_allocator)
	signed := jwt[:len(parts[0]) + 1 + len(parts[1])]
	testing.expect(t, ecdsa.verify_raw(&pub, .SHA256, transmute([]u8)signed, sig))
}

// ts_push_on enables push on a test server without starting the push thread, so the jobs
// it would send stay in s.push.jobs.
ts_push_on :: proc(t: ^testing.T, ts: ^Test_Server) {
	p := &ts.s.push
	encoded, ok := vapid_key_generate(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, vapid_key_parse(encoded, &p.key))
	ecdsa.private_key_public_bytes(&p.key, p.public[:])
	p.enabled = true
}

@(private = "file")
subscribe_body :: proc(endpoint: string, seed: u8) -> []u8 {
	sub := proto.Push_Subscription {
		endpoint = endpoint,
	}
	sub.p256dh[0] = 4
	sub.p256dh[1] = seed
	sub.auth[0] = seed
	buf := make([]u8, proto.PUSH_SUBSCRIBE_MAX_SIZE, context.temp_allocator)
	body, _ := proto.encode_push_subscribe(buf, sub)
	return body
}

@(test)
test_push_subscriptions :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	alice := ts_account(t, &ts, "alice", "a password")
	phone := ts_connect(&ts)
	status, _ := ts_login(t, &ts, phone, "alice", "a password", "phone")
	testing.expect_value(t, status, proto.Status.Ok)

	// A server without push rejects subscriptions and doesn't advertise a key.
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/a", 1),
	)
	testing.expect_value(t, status, proto.Status.Closed)
	body: []u8
	status, body = ts_ask(t, &ts, phone, .Server_Info)
	info, _ := proto.decode_server_info(body)
	testing.expect_value(t, len(info.push_key), 0)

	ts_push_on(t, &ts)
	status, body = ts_ask(t, &ts, phone, .Server_Info)
	info, _ = proto.decode_server_info(body)
	testing.expect(t, string(info.push_key) == string(ts.s.push.public[:]))

	// Only https:// endpoints with a path are accepted.
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("http://push.example.net/a", 1),
	)
	testing.expect_value(t, status, proto.Status.Invalid)
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net", 1),
	)
	testing.expect_value(t, status, proto.Status.Invalid)

	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/a", 1),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	subs := push_subs_of(&ts.s, alice.id)
	testing.expect_value(t, len(subs), 1)
	testing.expect_value(t, subs[0].endpoint, "https://push.example.net/a")
	testing.expect_value(t, subs[0].auth[0], 1)

	// Each device has one subscription: a new one replaces the old one.
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/b", 2),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	subs = push_subs_of(&ts.s, alice.id)
	testing.expect_value(t, len(subs), 1)
	testing.expect_value(t, subs[0].endpoint, "https://push.example.net/b")

	laptop := ts_connect(&ts)
	status, _ = ts_login(t, &ts, laptop, "alice", "a password", "laptop")
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_ask(
		t,
		&ts,
		laptop,
		.Push_Subscribe,
		subscribe_body("https://push.example.org/c", 3),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(push_subs_of(&ts.s, alice.id)), 2)

	// Unsubscribing only removes this device's subscription.
	status, _ = ts_ask(t, &ts, laptop, .Push_Unsubscribe)
	testing.expect_value(t, status, proto.Status.Ok)
	subs = push_subs_of(&ts.s, alice.id)
	testing.expect_value(t, len(subs), 1)
	testing.expect_value(t, subs[0].endpoint, "https://push.example.net/b")

	// A subscription that the push service reports as gone is deleted.
	ts.s.push.results = make([dynamic]Push_Result)
	append(&ts.s.push.results, Push_Result{subs[0].id, .Gone})
	push_sync(&ts.s)
	testing.expect_value(t, len(push_subs_of(&ts.s, alice.id)), 0)

	// Logging out deletes the device's subscription.
	status, _ = ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/d", 4),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(push_subs_of(&ts.s, alice.id)), 1)
	status, _ = ts_ask(t, &ts, phone, .Auth_Logout)
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(push_subs_of(&ts.s, alice.id)), 0)
}

// A push queued by the server loop: its decoded payload, and its delivery options.
@(private = "file")
Sent_Push :: struct {
	using payload: Push_Payload,
	endpoint:      string,
	ttl:           int,
	urgency:       Push_Urgency,
}

// pushes_sent takes the pushes the server loop has queued and clears the queue.
@(private = "file")
pushes_sent :: proc(t: ^testing.T, ts: ^Test_Server) -> []Sent_Push {
	p := &ts.s.push
	out := make([]Sent_Push, len(p.jobs), context.temp_allocator)
	for &job, i in p.jobs {
		json.unmarshal(job.payload, &out[i].payload, allocator = context.temp_allocator)
		out[i].endpoint = strings.clone(job.endpoint, context.temp_allocator)
		out[i].ttl, out[i].urgency = job.ttl, job.urgency
		// Pushes for the same notification share a topic, so they replace each other while
		// waiting at the push service.
		testing.expect_value(t, job.topic, out[i].tag)
		delete(job.endpoint)
		delete(job.topic)
		delete(job.payload)
	}
	clear(&p.jobs)
	return out
}

@(test)
test_push_messages :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	ts_push_on(t, &ts)
	s.name = "Test server"
	defer s.name = ""
	home := s.convs.home
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	status, _ := ts_ask(
		t,
		&ts,
		alice,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/a", 1),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	tok := proto.mention_token(alice_acc.id)

	ab: [4]u8
	answer: []u8
	status, answer = ts_ask(t, &ts, bob, .DM_Open, proto.encode_account_id(&ab, alice_acc.id))
	testing.expect_value(t, status, proto.Status.Ok)
	dm, _ := proto.decode_conv_id(answer)

	// Alice is present: her desktop notifies her, so nothing is pushed.
	post(t, &ts, bob, dm, "here?", 1)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 0)

	// Her page is hidden: the message is pushed, even though she isn't away.
	idle: [1]u8
	status, _ = ts_ask(t, &ts, alice, .Idle_Set, proto.encode_idle(&idle, false, hidden = true))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, activity_of(alice_acc), proto.Activity.Online)
	post(t, &ts, bob, dm, "hidden?", 7)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 1)

	// She is idle: the message is pushed.
	status, _ = ts_ask(t, &ts, alice, .Idle_Set, proto.encode_idle(&idle, true))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, activity_of(alice_acc), proto.Activity.Away)
	post(t, &ts, bob, dm, fmt.tprintf("hi %s,\n  lunch?", tok), 2)
	sent := pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 1)
	if len(sent) == 1 {
		testing.expect_value(t, sent[0].kind, "dm")
		testing.expect_value(t, sent[0].tag, fmt.tprintf("c%d", dm))
		testing.expect_value(t, sent[0].urgency, Push_Urgency.High)
		testing.expect_value(t, sent[0].server, "Test server")
		testing.expect_value(t, sent[0].conv, u32(dm))
		testing.expect_value(t, sent[0].title, "bob messaged you")
		testing.expect_value(t, sent[0].body, "hi @alice, lunch?")
	}

	// She is disconnected: mentions are pushed, other channel messages aren't.
	ts_disconnect(&ts, alice)
	post(t, &ts, carol, home.id, "chatter", 3)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 0)
	post(t, &ts, carol, home.id, fmt.tprintf("look, %s", tok), 4)
	sent = pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 1)
	if len(sent) == 1 {
		testing.expect_value(t, sent[0].kind, "mention")
		testing.expect_value(t, sent[0].title, "carol mentioned you in #Lobby")
		testing.expect_value(t, sent[0].body, "look, @alice")
	}
	// Nothing is pushed for a conversation she muted.
	notify: [proto.CONV_NOTIFY_SIZE]u8
	again := logged_in(t, &ts, "alice")
	status, _ = ts_ask(t, &ts, again, .Conv_Notify, proto.encode_conv_notify(&notify, dm, .None))
	testing.expect_value(t, status, proto.Status.Ok)
	ts_disconnect(&ts, again)
	post(t, &ts, bob, dm, "muted", 5)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 0)

	// The message text is left out if she chose to hide it.
	again = logged_in(t, &ts, "alice")
	setting: [proto.SETTING_MAX_SIZE]u8
	body := proto.encode_setting(
		setting[:],
		proto.SETTING_PUSH_TEXT,
		transmute([]u8)string(proto.PUSH_TEXT_HIDDEN),
	)
	status, _ = ts_ask(t, &ts, again, .Setting_Set, body)
	testing.expect_value(t, status, proto.Status.Ok)
	ts_disconnect(&ts, again)
	post(t, &ts, carol, home.id, fmt.tprintf("secret, %s", tok), 6)
	sent = pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 1)
	if len(sent) == 1 {
		testing.expect_value(t, sent[0].title, "carol mentioned you in #Lobby")
		testing.expect_value(t, sent[0].body, "")
	}
}

@(test)
test_push_calls :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	ts_push_on(t, &ts)
	alice_acc := ts_account(t, &ts, "alice", "a password")
	carol_acc := ts_account(t, &ts, "carol", "a password")
	ts_account(t, &ts, "bob", "a password")
	phone := logged_in(t, &ts, "alice")
	laptop := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	status, _ := ts_ask(
		t,
		&ts,
		phone,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/phone", 1),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	status, _ = ts_ask(
		t,
		&ts,
		laptop,
		.Push_Subscribe,
		subscribe_body("https://push.example.net/laptop", 2),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	phone_key := phone.key
	ts_disconnect(&ts, phone)
	ts_disconnect(&ts, laptop)

	// Alice has no connection, but has push subscriptions: the call rings anyway.
	buf: [4]u8
	body: []u8
	status, body = ts_ask(t, &ts, bob, .Call_Start, proto.encode_account_id(&buf, alice_acc.id))
	testing.expect_value(t, status, proto.Status.Ok)
	call, _ := proto.decode_call_id(body)
	sent := pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 2)
	if len(sent) == 2 {
		testing.expect_value(t, sent[0].kind, "call")
		testing.expect_value(t, sent[0].title, "bob is calling you")
		testing.expect(t, sent[0].ring && !sent[0].quiet)
		testing.expect_value(t, sent[0].ttl, proto.CALL_RING_SECONDS)
		testing.expect_value(t, sent[0].tag, fmt.tprintf("call%d", call))
	}

	// The phone that the push woke up is told the call is ringing, and answers it.
	phone = ts_connect(&ts, phone_key)
	testing.expect(t, phone.account == alice_acc)
	rang := false
	for e in ts_events(t, &ts, phone) {
		rang ||= e.op == .Call_Ring
	}
	testing.expect(t, rang)
	status, _ = ts_ask(t, &ts, phone, .Call_Accept, proto.encode_call_id(&buf, call))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 0)

	// The call ends: the laptop is silently told it was answered elsewhere; the phone that
	// answered isn't told anything.
	status, _ = ts_ask(t, &ts, bob, .Call_End, proto.encode_call_id(&buf, call))
	testing.expect_value(t, status, proto.Status.Ok)
	sent = pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 1)
	if len(sent) == 1 {
		testing.expect_value(t, sent[0].endpoint, "https://push.example.net/laptop")
		testing.expect_value(t, sent[0].title, "Call with bob")
		testing.expect(t, sent[0].quiet && !sent[0].ring)
	}

	// A call while she's away that the caller gives up on: a missed call notification
	// replaces the ringing one.
	ts_disconnect(&ts, phone)
	status, body = ts_ask(t, &ts, bob, .Call_Start, proto.encode_account_id(&buf, alice_acc.id))
	testing.expect_value(t, status, proto.Status.Ok)
	call, _ = proto.decode_call_id(body)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 2)
	status, _ = ts_ask(t, &ts, bob, .Call_End, proto.encode_call_id(&buf, call))
	testing.expect_value(t, status, proto.Status.Ok)
	sent = pushes_sent(t, &ts)
	testing.expect_value(t, len(sent), 2)
	if len(sent) == 2 {
		testing.expect_value(t, sent[0].title, "Missed call from bob")
		testing.expect(t, !sent[0].quiet && !sent[0].ring)
		testing.expect_value(t, sent[0].urgency, Push_Urgency.Normal)
	}

	// Without push subscriptions, calling someone who isn't connected is still
	// immediately a missed call.
	status, _ = ts_ask(t, &ts, bob, .Call_Start, proto.encode_account_id(&buf, carol_acc.id))
	testing.expect_value(t, status, proto.Status.Closed)
	testing.expect_value(t, len(pushes_sent(t, &ts)), 0)
}
