package gateway

import "core:crypto/ecdh"
import "core:encoding/json"
import "core:net"
import "core:strings"
import "core:testing"

import "common:proto"
import "lib:http"
import "lib:lite"

// Tests of the parts of the gateway that decide things from what a request
// says: which endpoint it is for, whether it is let through, whether a
// password may be sent, and what the answer looks like. The whole path
// through the gateway and the server is tested by server/gateway_test.odin.

// ---- addresses ----

@(private = "file")
v4 :: proc(a, b, c, d: u8) -> net.Address {
	return net.IP4_Address{a, b, c, d}
}

// mapped makes the IPv6 form of an IPv4 address that a dual-stack socket reports.
@(private = "file")
mapped :: proc(a, b, c, d: u8) -> net.Address {
	return net.IP6_Address {
		0,
		0,
		0,
		0,
		0,
		0xffff,
		u16be(a) << 8 | u16be(b),
		u16be(c) << 8 | u16be(d),
	}
}

@(private = "file")
v6 :: proc(words: [8]u16) -> net.Address {
	out: [8]u16be
	for w, i in words {
		out[i] = u16be(w)
	}
	return net.IP6_Address(out)
}

@(test)
test_address_loopback :: proc(t: ^testing.T) {
	yes := []net.Address {
		v4(127, 0, 0, 1),
		v4(127, 255, 255, 254),
		net.IP6_Loopback,
		mapped(127, 0, 0, 1),
	}
	for a in yes {
		testing.expectf(t, address_loopback(a), "%v is not loopback", a)
	}
	no := []net.Address {
		nil,
		v4(0, 0, 0, 0),
		v4(126, 255, 255, 255),
		v4(128, 0, 0, 1),
		v4(10, 0, 0, 1),
		v4(8, 8, 8, 8),
		v6({0, 0, 0, 0, 0, 0, 0, 0}), // ::
		v6({0, 0, 0, 0, 0, 0, 0, 2}), // ::2
		v6({0x2001, 0xdb8, 0, 0, 0, 0, 0, 1}),
		mapped(8, 8, 8, 8),
		mapped(10, 0, 0, 1),
		// Looks like a mapped address but isn't: something is set in the first ten bytes.
		v6({1, 0, 0, 0, 0, 0xffff, 0x7f00, 1}),
	}
	for a in no {
		testing.expectf(t, !address_loopback(a), "%v is loopback", a)
	}
}

@(test)
test_address_private :: proc(t: ^testing.T) {
	yes := []net.Address {
		v4(127, 0, 0, 1),
		v4(10, 0, 0, 1),
		v4(10, 255, 255, 255),
		v4(172, 16, 0, 1),
		v4(172, 31, 255, 255),
		v4(192, 168, 0, 1),
		net.IP6_Loopback,
		v6({0xfc00, 0, 0, 0, 0, 0, 0, 1}),
		v6({0xfd12, 0x3456, 0, 0, 0, 0, 0, 1}),
		mapped(10, 1, 2, 3),
		mapped(192, 168, 1, 1),
	}
	for a in yes {
		testing.expectf(t, address_private(a), "%v is not private", a)
	}
	no := []net.Address {
		nil,
		v4(8, 8, 8, 8),
		v4(11, 0, 0, 1),
		v4(172, 15, 255, 255),
		v4(172, 32, 0, 1),
		v4(192, 167, 0, 1),
		v4(192, 169, 0, 1),
		v4(169, 254, 1, 1), // link-local is not a network a proxy is on
		v6({0xfe80, 0, 0, 0, 0, 0, 0, 1}),
		v6({0xfe00, 0, 0, 0, 0, 0, 0, 1}),
		v6({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}),
		mapped(8, 8, 8, 8),
	}
	for a in no {
		testing.expectf(t, !address_private(a), "%v is private", a)
	}
}

@(test)
test_unmapped :: proc(t: ^testing.T) {
	testing.expect_value(t, unmapped(mapped(1, 2, 3, 4)), v4(1, 2, 3, 4))
	testing.expect_value(t, unmapped(v4(1, 2, 3, 4)), v4(1, 2, 3, 4))
	other := v6({0x2001, 0xdb8, 0, 0, 0, 0, 0, 1})
	testing.expect_value(t, unmapped(other), other)
	// Not mapped if the marker is not exactly ffff.
	almost := v6({0, 0, 0, 0, 0, 0xfffe, 0x0102, 0x0304})
	testing.expect_value(t, unmapped(almost), almost)
	testing.expect(t, unmapped(nil) == nil)
}

@(test)
test_proxy_trusted :: proc(t: ^testing.T) {
	remote := func_endpoint(v4(10, 0, 0, 5))
	// Without a configured proxy, the machine itself and private networks are trusted.
	testing.expect(t, proxy_trusted(nil, remote))
	testing.expect(t, proxy_trusted(nil, func_endpoint(v4(127, 0, 0, 1))))
	testing.expect(t, proxy_trusted(nil, func_endpoint(mapped(192, 168, 1, 1))))
	testing.expect(t, !proxy_trusted(nil, func_endpoint(v4(8, 8, 8, 8))))
	// With one, only it is.
	testing.expect(t, proxy_trusted(v4(10, 0, 0, 5), remote))
	testing.expect(t, !proxy_trusted(v4(10, 0, 0, 6), remote))
	testing.expect(t, !proxy_trusted(v4(8, 8, 8, 8), func_endpoint(v4(127, 0, 0, 1))))
}

@(private = "file")
func_endpoint :: proc(a: net.Address) -> net.Endpoint {
	return {address = a, port = 40000}
}

@(test)
test_login_allowed :: proc(t: ^testing.T) {
	local := func_endpoint(v4(127, 0, 0, 1))
	lan := func_endpoint(v4(192, 168, 1, 7))
	far := func_endpoint(v4(8, 8, 8, 8))

	// Without a proxy a password is only taken over loopback.
	testing.expect(t, login_allowed(false, nil, local, ""))
	testing.expect(t, login_allowed(false, nil, func_endpoint(mapped(127, 0, 0, 1)), ""))
	testing.expect(t, login_allowed(false, nil, func_endpoint(net.IP6_Loopback), ""))
	testing.expect(t, !login_allowed(false, nil, lan, ""))
	testing.expect(t, !login_allowed(false, nil, far, ""))
	// What a header says doesn't matter when there is no proxy to believe.
	testing.expect(t, !login_allowed(false, nil, far, "https"))
	testing.expect(t, !login_allowed(false, nil, lan, "https"))

	// Behind a proxy it has to say that the bot used HTTPS, and be the proxy.
	testing.expect(t, login_allowed(true, nil, local, "https"))
	testing.expect(t, login_allowed(true, nil, lan, "https"))
	testing.expect(t, login_allowed(true, nil, lan, "HTTPS"))
	testing.expect(t, login_allowed(true, nil, lan, "  https "))
	testing.expect(t, !login_allowed(true, nil, lan, "http"))
	testing.expect(t, !login_allowed(true, nil, lan, ""))
	testing.expect(t, !login_allowed(true, nil, lan, "https, http"))
	testing.expect(t, !login_allowed(true, nil, lan, "httpsx"))
	// Loopback is not enough behind a proxy: the proxy has to vouch for the request.
	testing.expect(t, !login_allowed(true, nil, local, "http"))
	// A request that did not come from the proxy can claim anything.
	testing.expect(t, !login_allowed(true, nil, far, "https"))
	testing.expect(
		t,
		login_allowed(true, v4(10, 1, 1, 1), func_endpoint(v4(10, 1, 1, 1)), "https"),
	)
	testing.expect(t, !login_allowed(true, v4(10, 1, 1, 1), lan, "https"))
	testing.expect(t, !login_allowed(true, v4(10, 1, 1, 1), local, "https"))
}

@(test)
test_client_address :: proc(t: ^testing.T) {
	g := Gateway {
		cfg = {behind_proxy = true},
	}
	proxy := http.Conn {
		remote = func_endpoint(v4(10, 0, 0, 2)),
	}
	request :: proc(forwarded: string) -> http.Request {
		headers := make([]http.Header, 1, context.temp_allocator)
		headers[0] = {"X-Forwarded-For", forwarded}
		return {headers = headers}
	}

	// Behind a trusted proxy, the address it appended (the last) is the client's.
	req := request("1.2.3.4")
	testing.expect_value(t, client_address(&g, &proxy, &req), v4(1, 2, 3, 4))
	// An earlier entry is whatever the client claimed, and is not believed.
	req = request("6.6.6.6, 1.2.3.4")
	testing.expect_value(t, client_address(&g, &proxy, &req), v4(1, 2, 3, 4))
	req = request("6.6.6.6,5.5.5.5 ,  1.2.3.4 ")
	testing.expect_value(t, client_address(&g, &proxy, &req), v4(1, 2, 3, 4))
	req = request("2001:db8::1")
	testing.expect_value(t, client_address(&g, &proxy, &req), net.parse_address("2001:db8::1"))

	// Without a usable header, the proxy's own address stands.
	for bad in ([]string{"", "garbage", "1.2.3.4, not-an-address", "1.2.3.4,"}) {
		req = request(bad)
		testing.expectf(
			t,
			client_address(&g, &proxy, &req) == proxy.remote.address,
			"%q was believed",
			bad,
		)
	}
	none := http.Request{}
	testing.expect(t, client_address(&g, &proxy, &none) == proxy.remote.address)

	// From a machine that isn't the proxy, the header is not believed.
	stranger := http.Conn {
		remote = func_endpoint(v4(8, 8, 8, 8)),
	}
	req = request("1.2.3.4")
	testing.expect_value(t, client_address(&g, &stranger, &req), v4(8, 8, 8, 8))
	// ... nor when no proxy is configured.
	g.cfg.behind_proxy = false
	testing.expect_value(t, client_address(&g, &proxy, &req), v4(10, 0, 0, 2))
	// ... nor from the wrong one of two private machines.
	g.cfg = {
		behind_proxy  = true,
		trusted_proxy = v4(10, 0, 0, 9),
	}
	testing.expect_value(t, client_address(&g, &proxy, &req), v4(10, 0, 0, 2))
}

// ---- rates ----

@(private = "file")
new_key :: proc(t: ^testing.T) -> ecdh.Private_Key {
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	return key
}

@(test)
test_rate_limit_per_token :: proc(t: ^testing.T) {
	g := Gateway {
		cfg = {rate = 0.1, burst = 3},
	}
	defer proto.keyed_buckets_destroy(&g.buckets)
	a, b := new_key(t), new_key(t)
	defer ecdh.private_key_clear(&a)
	defer ecdh.private_key_clear(&b)

	// A burst is let through, then the token is asked to slow down.
	for i in 0 ..< 3 {
		_, limited := rate_take(&g, &a)
		testing.expectf(t, !limited, "request %d was limited", i)
	}
	r, limited := rate_take(&g, &a)
	defer delete(r.json)
	testing.expect(t, limited)
	testing.expect_value(t, r.status, 429)
	// One request's worth of tokens takes 1 / rate seconds to come back.
	testing.expect_value(t, r.retry_after, 10)
	testing.expect(t, strings.contains(r.json, `"rate_limited"`))

	// Another token has a bucket of its own.
	_, other := rate_take(&g, &b)
	testing.expect(t, !other)
}

@(test)
test_rate_limit_options :: proc(t: ^testing.T) {
	// A rate of 0 means no limit.
	g := Gateway {
		cfg = {rate = 0, burst = 1},
	}
	defer proto.keyed_buckets_destroy(&g.buckets)
	key := new_key(t)
	defer ecdh.private_key_clear(&key)
	for _ in 0 ..< 100 {
		_, limited := rate_take(&g, &key)
		testing.expect(t, !limited)
	}
	testing.expect_value(t, len(g.buckets.by_key), 0)

	// A burst of 0 still lets one request through at a time.
	g.cfg = {
		rate  = 1000,
		burst = 0,
	}
	_, limited := rate_take(&g, &key)
	testing.expect(t, !limited)
	// A fast rate says to try again in a second at the soonest.
	r: Reply
	for _ in 0 ..< 10 {
		r, limited = rate_take(&g, &key)
		if limited {
			break
		}
	}
	defer delete(r.json)
	testing.expect(t, limited)
	testing.expect_value(t, r.retry_after, 1)
}

@(test)
test_new_connections_per_address :: proc(t: ^testing.T) {
	g: Gateway
	defer proto.keyed_buckets_destroy(&g.opens)

	// Some are let through, then the address is asked to slow down.
	a := v4(1, 2, 3, 4)
	for i in 0 ..< OPENS_PER_ADDRESS {
		_, limited := opens_take(&g, a)
		testing.expectf(t, !limited, "open %d was limited", i)
	}
	r, limited := opens_take(&g, a)
	defer delete(r.json)
	testing.expect(t, limited)
	testing.expect_value(t, r.status, 429)
	testing.expect(t, r.retry_after >= 1 && r.retry_after <= int(OPEN_EVERY / 1e9))

	// Other addresses are not affected, and the IPv4 and IPv6 forms of one
	// number are different addresses.
	_, other := opens_take(&g, v4(1, 2, 3, 5))
	testing.expect(t, !other)
	_, other = opens_take(&g, v6({0, 0, 0, 0, 0, 0, 0x0102, 0x0304}))
	testing.expect(t, !other)
	// A job without an address (made by hand in tests) is not limited.
	for _ in 0 ..< 3 * OPENS_PER_ADDRESS {
		_, other = opens_take(&g, nil)
		testing.expect(t, !other)
	}
}

// ---- routes ----

@(private = "file")
get :: proc(method, path: string) -> http.Request {
	return {method = method, path = path, content_length = -1}
}

@(test)
test_match_routes :: proc(t: ^testing.T) {
	req := get("GET", "/api/v1/me")
	route, params, ok := match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.pattern, "me")
	testing.expect_value(t, route.kind, Job_Kind.Call)

	// Parameters come out in order, decoded.
	req = get("GET", "/api/v1/convs/12/messages")
	route, params, ok = match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.pattern, "convs/{}/messages")
	testing.expect_value(t, params[0], "12")
	testing.expect_value(t, params[1], "")

	req = get("PUT", "/api/v1/messages/55/reactions/%F0%9F%91%8D")
	route, params, ok = match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.pattern, "messages/{}/reactions/{}")
	testing.expect_value(t, params[0], "55")
	testing.expect_value(t, params[1], "👍")

	// A fixed segment before a parameter in the same place wins.
	req = get("GET", "/api/v1/convs/browse")
	route, _, ok = match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.pattern, "convs/browse")
	req = get("GET", "/api/v1/convs/browsed")
	route, params, ok = match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.pattern, "convs/{}")
	testing.expect_value(t, params[0], "browsed")

	// The method is part of the route.
	req = get("POST", "/api/v1/convs/12/messages")
	route, _, ok = match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, route.run == nil, false)
	testing.expect_value(t, route.method, "POST")
}

@(test)
test_match_refuses :: proc(t: ^testing.T) {
	for path in ([]string {
			"/",
			"/api",
			"/api/",
			"/api/v1",
			"/api/v2/me",
			"/api/v1/",
			"/api/v1/nothing",
			"/api/v1/me/",
			"/api/v1/me/extra",
			"/api/v1/convs//messages", // an empty parameter
			"/api/v1/convs/1/messages/extra",
			"/api/v1/convs/%zz/messages", // not decodable
			"/api/v1/Me",
			"api/v1/me",
			"/v1/me",
			"/api/v1/../v1/me",
		}) {
		req := get("GET", path)
		route, _, ok := match(&req)
		testing.expectf(t, !ok, "%q matched %q", path, route.pattern if ok else "")
	}
	for method in ([]string{"", "get", "HEAD", "OPTIONS", "TRACE", "CONNECT"}) {
		req := get(method, "/api/v1/me")
		_, _, ok := match(&req)
		testing.expectf(t, !ok, "method %q matched", method)
	}
	// A parameter may hold an encoded slash without becoming two segments.
	req := get("GET", "/api/v1/convs/a%2Fb")
	_, params, ok := match(&req)
	testing.expect(t, ok)
	testing.expect_value(t, params[0], "a/b")
}

@(test)
test_routes_are_consistent :: proc(t: ^testing.T) {
	seen: map[string]bool
	defer delete(seen)
	for r, i in ROUTES {
		key := strings.concatenate({r.method, " ", r.pattern}, context.temp_allocator)
		testing.expectf(t, key not_in seen, "%s is listed twice", key)
		seen[key] = true

		// A login has no run; everything else has one.
		testing.expectf(t, (r.run != nil) != (r.kind == .Login), "%s: run", key)
		testing.expectf(t, (r.prepare != nil) == (r.kind == .Login), "%s: prepare", key)

		segments := strings.split(r.pattern, "/", context.temp_allocator)
		params := 0
		for s in segments {
			testing.expectf(t, s != "", "%s has an empty segment", key)
			if s == "{}" {
				params += 1
			}
		}
		testing.expectf(t, params <= len(Job{}.params), "%s has too many parameters", key)

		// A route must not be hidden by an earlier one: the first that matches
		// is used, so a pattern with {} has to come after the fixed ones it
		// would also match.
		concrete := make([]string, len(segments), context.temp_allocator)
		for s, k in segments {
			concrete[k] = "x" if s == "{}" else s
		}
		for earlier in ROUTES[:i] {
			if earlier.method != r.method {
				continue
			}
			_, shadows := match_pattern(earlier.pattern, concrete)
			if shadows && earlier.pattern != r.pattern {
				// Fine if the earlier one is the more specific (a fixed
				// segment where this one has {}): the walk above used "x",
				// which a fixed segment other than "x" doesn't match, so
				// reaching here means the earlier one has {} there.
				testing.expectf(t, false, "%s is hidden by %s", key, earlier.pattern)
			}
		}
	}
}

@(test)
test_route_missing :: proc(t: ^testing.T) {
	// A path that exists for other methods says which.
	req := get("DELETE", "/api/v1/me")
	r := route_missing(&req)
	defer delete(r.json)
	testing.expect_value(t, r.status, 405)
	allowed := strings.split(r.allow, ", ", context.temp_allocator)
	testing.expect_value(t, len(allowed), 2)
	testing.expect(t, strings.contains(r.allow, "GET") && strings.contains(r.allow, "PATCH"))

	req = get("PATCH", "/api/v1/convs/3/subscription")
	r2 := route_missing(&req)
	defer delete(r2.json)
	testing.expect_value(t, r2.status, 405)
	testing.expect(t, strings.contains(r2.allow, "PUT") && strings.contains(r2.allow, "DELETE"))
	testing.expect(t, !strings.contains(r2.allow, "PATCH"))

	// Nothing there at all.
	req = get("GET", "/api/v1/nowhere")
	r3 := route_missing(&req)
	defer delete(r3.json)
	testing.expect_value(t, r3.status, 404)
	testing.expect_value(t, r3.allow, "")
	testing.expect(t, strings.contains(r3.json, `"not_found"`))

	// Outside of the API.
	req = get("GET", "/elsewhere")
	r4 := route_missing(&req)
	defer delete(r4.json)
	testing.expect_value(t, r4.status, 404)
}

// ---- tokens ----

@(test)
test_take_token :: proc(t: ^testing.T) {
	g := Gateway {
		cfg = {rate = 0},
	}
	token, _, ok := proto.bot_token_make(context.temp_allocator)
	testing.expect(t, ok)

	req_with :: proc(auth: string) -> http.Request {
		headers: []http.Header
		if auth != "" {
			headers = make([]http.Header, 1, context.temp_allocator)
			headers[0] = {"Authorization", auth}
		}
		return {headers = headers}
	}

	j: Job
	defer ecdh.private_key_clear(&j.key)
	req := req_with(strings.concatenate({"Bot ", token}, context.temp_allocator))
	r, refused := take_token(&g, &j, &req)
	testing.expect(t, !refused)
	testing.expect_value(t, r.status, 0)
	// The scheme is not case sensitive.
	req = req_with(strings.concatenate({"bot ", token}, context.temp_allocator))
	_, refused = take_token(&g, &j, &req)
	testing.expect(t, !refused)

	for bad in ([]string {
			"",
			"Bot",
			"Bot ",
			"Bot nonsense",
			"Bearer " + "x",
			strings.concatenate({"Basic ", token}, context.temp_allocator),
			strings.concatenate({"Bearer ", token}, context.temp_allocator),
			token, // no scheme
			strings.concatenate({"Bot ", token[:len(token) - 1]}, context.temp_allocator),
			strings.concatenate({"Bot ", token, "A"}, context.temp_allocator),
		}) {
		var: Job
		req = req_with(bad)
		r, refused = take_token(&g, &var, &req)
		testing.expectf(t, refused, "%q was accepted", bad)
		testing.expect_value(t, r.status, 401)
		delete(r.json)
		ecdh.private_key_clear(&var.key)
	}
}

// ---- replies ----

@(test)
test_status_replies :: proc(t: ^testing.T) {
	// Every status has an answer that says what went wrong, as JSON.
	for status in proto.Status {
		r := status_reply(status)
		defer delete(r.json)
		if status == .Ok {
			testing.expect_value(t, r.status, 204)
			testing.expect_value(t, r.json, "")
			continue
		}
		testing.expectf(t, r.status >= 400 && r.status < 600, "%v: %d", status, r.status)
		body: Error_JSON
		testing.expectf(
			t,
			json.unmarshal(transmute([]u8)r.json, &body, allocator = context.temp_allocator) ==
			nil,
			"%v: %q is not JSON",
			status,
			r.json,
		)
		testing.expectf(t, body.error != "" && body.message != "", "%v: %q", status, r.json)
	}

	Case :: struct {
		status: proto.Status,
		http:   int,
		code:   string,
	}
	for c in ([]Case {
			{.Invalid, 400, "invalid"},
			{.Unauthenticated, 401, "unauthenticated"},
			{.Wrong_Password, 401, "wrong_password"},
			{.Denied, 403, "denied"},
			{.Banned, 403, "banned"},
			{.Not_Found, 404, "not_found"},
			{.Conflict, 409, "conflict"},
			{.Closed, 410, "closed"},
			{.Too_Large, 413, "too_large"},
			{.Rate_Limited, 429, "rate_limited"},
			{.Internal, 500, "internal"},
			{.Unknown_Op, 501, "unknown_op"},
			{.Reset, 503, "reset"},
			{.Quota, 507, "quota"},
		}) {
		r := status_reply(c.status)
		defer delete(r.json)
		testing.expectf(t, r.status == c.http, "%v: %d", c.status, r.status)
		testing.expectf(t, strings.contains(r.json, c.code), "%v: %q", c.status, r.json)
	}
	// A bot asked to slow down is told when to come back.
	r := status_reply(.Rate_Limited)
	defer delete(r.json)
	testing.expect_value(t, r.retry_after, 1)
}

@(test)
test_failure_replies :: proc(t: ^testing.T) {
	c: lite.Client
	for failure in lite.Failure {
		c.failure = failure
		c.login_status = .Wrong_Password
		r := failure_reply(&c)
		defer delete(r.json)
		testing.expectf(t, r.status >= 400, "%v", failure)
		testing.expectf(t, r.json != "", "%v", failure)
	}
	Case :: struct {
		failure: lite.Failure,
		http:    int,
	}
	for k in ([]Case {
			{.Not_Logged_In, 401},
			{.Logged_Out, 401},
			{.Login_Failed, 401}, // for a wrong password
			{.Refused, 502},
			{.Wrong_Server_Key, 502},
			{.Lost, 503},
			{.None, 500},
		}) {
		c.failure = k.failure
		c.login_status = .Wrong_Password
		r := failure_reply(&c)
		defer delete(r.json)
		testing.expectf(t, r.status == k.http, "%v: %d", k.failure, r.status)
	}
	// A failed login says why, with the same answer a status would get.
	c.failure, c.login_status = .Login_Failed, .Rate_Limited
	r := failure_reply(&c)
	defer delete(r.json)
	testing.expect_value(t, r.status, 429)
	// A logout says by whom.
	c.failure, c.logout_reason = .Logged_Out, .Banned
	r2 := failure_reply(&c)
	defer delete(r2.json)
	testing.expect(t, strings.contains(r2.json, "Banned"))
}

@(test)
test_json_replies :: proc(t: ^testing.T) {
	r := json_reply(200, struct {
		a: int,
		b: string,
	}{1, "x\"y"})
	defer delete(r.json)
	testing.expect_value(t, r.status, 200)
	testing.expect_value(t, r.json, `{"a":1,"b":"x\"y"}`)

	e := error_reply(418, "teapot", `short "and" stout`)
	defer delete(e.json)
	testing.expect_value(t, e.status, 418)
	testing.expect_value(t, e.json, `{"error":"teapot","message":"short \"and\" stout"}`)

	empty := empty_reply()
	testing.expect_value(t, empty.status, 204)
	testing.expect_value(t, empty.json, "")
}
