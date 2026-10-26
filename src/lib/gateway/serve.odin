package gateway

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

import "common:proto"
import "lib:http"
import "lib:lite"

// This is the HTTP side: what an HTTP thread does with the API's requests, all
// of which are under API_PREFIX. Each request is matched to a Route, its token
// is checked and its body is read. It is then turned into a Job for the
// gateway thread (gateway.odin) and answered with the Job's reply as JSON.
// A failure looks like this:
//
//	{"error": "denied", "message": "You can't post in this channel."}
//
// The protocol's statuses are mapped to HTTP statuses as in status_reply.

API_PREFIX :: "/api/"
V1_PREFIX :: "/api/v1/"
// The maximum size of a request body. Uploads are exempt because they are
// streamed.
MAX_BODY :: 64 * 1024

// A Route is an endpoint with its method and its path under V1_PREFIX. A {}
// segment is a parameter (an id) and is stored in Job.params in order.
// `prepare` runs on the HTTP thread to validate and parse the request before
// there is a Job to hand over. It returns a reply only if the request is
// finished at that point.
Route :: struct {
	method:  string,
	pattern: string,
	kind:    Job_Kind,
	prepare: proc(j: ^Job, req: ^http.Request) -> (r: Reply, done: bool),
	run:     proc(c: ^Conn, j: ^Job),
}

// serve answers API requests on an HTTP connection: first `first`, whose head
// the caller has already read, and then as many more as the client sends
// while it keeps the connection open. It returns when the connection should
// be closed, which the caller then does. The temp allocations of each request
// are freed before the next one.
serve :: proc(g: ^Gateway, c: ^http.Conn, first: http.Request) {
	idle_timeout(c, HTTP_IDLE)
	req := first
	for {
		if !handle(g, c, &req) {
			return
		}
		free_all(context.temp_allocator)
		head, ok := http.read_head(c)
		if !ok {
			return
		}
		req, ok = http.parse_request(head)
		if !ok {
			send(c, error_reply(400, "invalid", "The request could not be parsed as HTTP."), false)
			return
		}
		if !strings.has_prefix(req.path, API_PREFIX) {
			send(c, error_reply(404, "not_found", "Only the API is served here."), false)
			return
		}
	}
}

// handle answers one request. It returns whether the connection stays open
// for another request.
@(private)
handle :: proc(g: ^Gateway, c: ^http.Conn, req: ^http.Request) -> (keep_alive: bool) {
	// Requests that stream their body or their answer handle themselves.
	if req.path == V1_PREFIX + "uploads" {
		return uploads_serve(g, c, req)
	}
	if strings.has_prefix(req.path, V1_PREFIX + "attachments/") && req.method == "GET" {
		if req.content_length > 0 {
			send(c, error_reply(400, "invalid", "A GET request must not have a body."), false)
			return false
		}
		return downloads_serve(g, c, req, req.path[len(V1_PREFIX + "attachments/"):])
	}
	if req.chunked {
		send(
			c,
			error_reply(411, "invalid", "A request body needs a Content-Length header."),
			false,
		)
		return false
	}
	if req.content_length > MAX_BODY {
		send(
			c,
			error_reply(
				413,
				"too_large",
				fmt.tprintf("The request body can be at most %d bytes.", MAX_BODY),
			),
			false,
		)
		return false
	}
	body: []u8
	if req.content_length > 0 {
		body = make([]u8, req.content_length, context.temp_allocator)
		if !http.read_body(c, body) {
			return false
		}
	}
	keep_alive = req.keep_alive

	if req.path == V1_PREFIX + "events" {
		if req.method != "GET" {
			r := error_reply(
				405,
				"method_not_allowed",
				"The event socket only accepts GET requests.",
			)
			r.allow = "GET"
			send(c, r, false)
		} else {
			events_serve(g, c, req)
		}
		return false
	}
	route, params, found := match(req)
	if !found {
		send(c, route_missing(req), keep_alive)
		return
	}
	j := Job {
		kind   = route.kind,
		run    = route.run,
		remote = client_address(g, c, req),
		body   = body,
		query  = req.query,
		params = params,
	}
	switch route.kind {
	case .Call:
		if r, refused := take_token(g, &j, req); refused {
			send(c, r, keep_alive)
			return
		}
	case .Login:
		if !login_allowed(
			g.cfg.behind_proxy,
			g.cfg.trusted_proxy,
			c.remote,
			http.header(req, "X-Forwarded-Proto"),
		) {
			send(
				c,
				error_reply(
					403,
					"denied",
					"A password may only be sent over HTTPS through a reverse proxy with TLS (api.behind_proxy), or from the same machine as the gateway.",
				),
				keep_alive,
			)
			return
		}
	case .Guest:
	}
	if route.prepare != nil {
		if r, done := route.prepare(&j, req); done {
			send(c, r, keep_alive)
			return
		}
	}
	send(c, submit(g, &j), keep_alive)
	return
}

// match finds the route for a request and its path parameters.
@(private)
match :: proc(req: ^http.Request) -> (route: ^Route, params: [4]string, ok: bool) {
	if !strings.has_prefix(req.path, V1_PREFIX) {
		return
	}
	segments := strings.split(req.path[len(V1_PREFIX):], "/", context.temp_allocator)
	for &r in ROUTES {
		if r.method != req.method {
			continue
		}
		if p, matched := match_pattern(r.pattern, segments); matched {
			return &r, p, true
		}
	}
	return
}

@(private)
match_pattern :: proc(pattern: string, segments: []string) -> (params: [4]string, ok: bool) {
	want := strings.split(pattern, "/", context.temp_allocator)
	if len(want) != len(segments) {
		return
	}
	n := 0
	for w, i in want {
		switch {
		case w == "{}":
			if segments[i] == "" || n == len(params) {
				return
			}
			params[n] = http.percent_decode(segments[i]) or_return
			n += 1
		case w != segments[i]:
			return
		}
	}
	return params, true
}

// route_missing explains why no route matched: either the path doesn't exist
// or it doesn't exist for that method.
@(private)
route_missing :: proc(req: ^http.Request) -> Reply {
	if strings.has_prefix(req.path, V1_PREFIX) {
		segments := strings.split(req.path[len(V1_PREFIX):], "/", context.temp_allocator)
		allowed := make([dynamic]string, context.temp_allocator)
		for r in ROUTES {
			if _, matched := match_pattern(r.pattern, segments); matched {
				append(&allowed, r.method)
			}
		}
		if len(allowed) > 0 {
			r := error_reply(
				405,
				"method_not_allowed",
				fmt.tprintf("%s does not accept %s requests.", req.path, req.method),
			)
			r.allow = strings.join(allowed[:], ", ", context.temp_allocator)
			return r
		}
	}
	return error_reply(404, "not_found", fmt.tprintf("There is nothing at %s.", req.path))
}

// take_token reads the token from `Authorization: Bot <token>` into the Job
// and takes a request from the token's bucket. If either fails, it returns the
// reply explaining why.
@(private)
take_token :: proc(g: ^Gateway, j: ^Job, req: ^http.Request) -> (r: Reply, refused: bool) {
	auth := http.header(req, "Authorization")
	scheme, _, token := strings.partition(auth, " ")
	if auth == "" {
		return error_reply(
				401,
				"unauthenticated",
				"A token is required: send the header Authorization: Bot <token>.",
			),
			true
	}
	if !strings.equal_fold(scheme, "Bot") || !proto.bot_token_parse(token, &j.key) {
		return error_reply(
				401,
				"unauthenticated",
				"The token is invalid. Send it as Authorization: Bot <token>.",
			),
			true
	}
	return rate_take(g, &j.key)
}

// send writes a reply and frees its JSON or bytes.
@(private)
send :: proc(c: ^http.Conn, r: Reply, keep_alive: bool) -> bool {
	r := r
	defer delete(r.json)
	defer delete(r.body)
	extra := strings.builder_make(context.temp_allocator)
	if r.status == 401 {
		strings.write_string(&extra, "WWW-Authenticate: Bot\r\n")
	}
	if r.retry_after > 0 {
		fmt.sbprintf(&extra, "Retry-After: %d\r\n", r.retry_after)
	}
	if r.allow != "" {
		fmt.sbprintf(&extra, "Allow: %s\r\n", r.allow)
	}
	if r.body != nil {
		return http.respond(
			c.sock,
			r.status,
			r.content_type,
			string(r.body),
			keep_alive,
			strings.to_string(extra),
		)
	}
	return http.respond(
		c.sock,
		r.status,
		"application/json; charset=utf-8",
		r.json,
		keep_alive,
		strings.to_string(extra),
	)
}

Error_JSON :: struct {
	error:   string,
	message: string,
}

// json_reply returns a reply with `v` as its JSON.
json_reply :: proc(status: int, v: any) -> Reply {
	data, err := json.marshal(v, allocator = context.allocator)
	if err != nil {
		log.errorf("api: could not make JSON of a %v: %v", v.id, err)
		return error_reply(500, "internal", "The response could not be converted to JSON.")
	}
	return {status = status, json = string(data)}
}

// empty_reply returns a successful reply without content (204).
empty_reply :: proc() -> Reply {
	return {status = 204}
}

error_reply :: proc(status: int, code, message: string) -> Reply {
	return json_reply(status, Error_JSON{code, message})
}

// status_reply returns the error for a protocol status other than Ok, using
// the mapping from the plan (docs/bot-api, "Errors").
status_reply :: proc(status: proto.Status) -> Reply {
	switch status {
	case .Ok:
		return empty_reply()
	case .Invalid:
		return error_reply(400, "invalid", "The server rejected the request as invalid.")
	case .Unauthenticated:
		return error_reply(401, "unauthenticated", "The connection is not logged in.")
	case .Wrong_Password:
		return error_reply(401, "wrong_password", "Wrong username or password.")
	case .Denied:
		return error_reply(403, "denied", "The account is not allowed to do that.")
	case .Not_Found:
		return error_reply(404, "not_found", "The requested item was not found.")
	case .Conflict:
		return error_reply(
			409,
			"conflict",
			"The request conflicts with something that already exists.",
		)
	case .Too_Large:
		return error_reply(413, "too_large", "The request is too large.")
	case .Rate_Limited:
		r := error_reply(
			429,
			"rate_limited",
			"Too many requests at once. Please try again in a moment.",
		)
		r.retry_after = 1
		return r
	case .Closed:
		return error_reply(410, "closed", "That item is closed.")
	case .Banned:
		return error_reply(403, "banned", "The account is banned from this server.")
	case .Quota:
		return error_reply(
			507,
			"quota",
			"The account has uploaded as much as the server allows for now.",
		)
	case .Unknown_Op:
		return error_reply(501, "unknown_op", "The server is too old to support that.")
	case .Reset:
		return error_reply(
			503,
			"reset",
			"The connection to the server restarted before it answered. Please try again.",
		)
	case .Internal:
	}
	return error_reply(500, "internal", "Something went wrong on the server.")
}

// failure_reply returns the reply sent to Jobs that were waiting on a
// connection that failed.
failure_reply :: proc(c: ^lite.Client) -> Reply {
	switch c.failure {
	case .Not_Logged_In:
		return error_reply(
			401,
			"unauthenticated",
			"The server does not recognize this token, or it has been revoked.",
		)
	case .Logged_Out:
		return error_reply(
			401,
			"unauthenticated",
			fmt.tprintf("The token was logged out (%v).", c.logout_reason),
		)
	case .Login_Failed:
		return status_reply(c.login_status)
	case .Refused:
		return error_reply(502, "bad_gateway", "The server refused the API's connection.")
	case .Wrong_Server_Key:
		return error_reply(
			502,
			"bad_gateway",
			"The server's key does not match the key the API was configured to expect.",
		)
	case .Lost:
		return error_reply(503, "unavailable", "The server is not responding.")
	case .None:
	}
	return error_reply(500, "internal", "The connection failed.")
}

// A connection thread's temp allocations consist of a request's head, body and
// answer, so its temp allocator starts small instead of with the default
// 4 MiB (like the relay's, see server/relay.odin).
@(private)
CONNECTION_TEMP :: 64 * 1024

// serve_connection is the thread for an HTTP connection of a standalone
// gateway (src/gateway), started by http.accept_loop. It serves the API's
// requests and nothing else, and closes `c` when the client disconnects.
serve_connection :: proc(g: ^Gateway, c: ^http.Conn) {
	temp: runtime.Arena
	_ = runtime.arena_init(&temp, CONNECTION_TEMP, context.allocator)
	context.temp_allocator = runtime.arena_allocator(&temp)
	defer runtime.arena_destroy(&temp)
	defer http.conn_close(c)

	// Without it, a client that never sends a head would keep its thread.
	idle_timeout(c, HTTP_IDLE)
	head, ok := http.read_head(c)
	if !ok {
		return
	}
	req, parsed := http.parse_request(head)
	if !parsed {
		return
	}
	if !strings.has_prefix(req.path, API_PREFIX) {
		send(
			c,
			error_reply(404, "not_found", "Only the API is served here, under /api/v1/."),
			false,
		)
		return
	}
	serve(g, c, req)
}
