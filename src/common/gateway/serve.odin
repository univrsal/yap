package gateway

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"

import "common:http"
import "common:lite"
import "common:proto"

/*
The HTTP side: what an HTTP thread does with the API's requests, all
under API_PREFIX. Each is matched to a Route, its token checked and its
body read, made into a Job for the gateway thread (gateway.odin), and
answered with the Job's reply, as JSON:

	{"error": "denied", "message": "You can't post in this channel."}

for anything that isn't a success. The protocol's statuses map to HTTP
ones as status_reply has them.
*/

API_PREFIX :: "/api/"
V1_PREFIX :: "/api/v1/"
// The most a request's body may be. Uploads (later) will stream.
MAX_BODY :: 64 * 1024

/*
A Route is an endpoint: its method and path under V1_PREFIX, where a
{} segment is a parameter (an id), taken into Job.params in order.
`prepare` runs on the HTTP thread, to check and take apart the request
before there's a Job to hand over; it returns a reply only if that's
the end of it.
*/
Route :: struct {
	method:  string,
	pattern: string,
	kind:    Job_Kind,
	prepare: proc(j: ^Job, req: ^http.Request) -> (r: Reply, done: bool),
	run:     proc(c: ^Conn, j: ^Job),
}

/*
serve answers API requests on an HTTP connection: `first`, whose head
the caller has read, and then as many as the client sends while it
keeps the connection open. It returns when the connection is to close,
which the caller does. Every request's temp allocations are freed
before the next.
*/
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
			send(c, error_reply(400, "invalid", "That isn't an HTTP request."), false)
			return
		}
		if !strings.has_prefix(req.path, API_PREFIX) {
			send(c, error_reply(404, "not_found", "Only the API is here."), false)
			return
		}
	}
}

// handle answers one request; it says whether the connection stays
// open for another.
@(private)
handle :: proc(g: ^Gateway, c: ^http.Conn, req: ^http.Request) -> (keep_alive: bool) {
	// What streams its body, or its answer, does it itself.
	if req.path == V1_PREFIX + "uploads" {
		return uploads_serve(g, c, req)
	}
	if strings.has_prefix(req.path, V1_PREFIX + "attachments/") && req.method == "GET" {
		if req.content_length > 0 {
			send(c, error_reply(400, "invalid", "A GET has no body."), false)
			return false
		}
		return downloads_serve(g, c, req, req.path[len(V1_PREFIX + "attachments/"):])
	}
	if req.chunked {
		send(c, error_reply(411, "invalid", "A body needs a Content-Length."), false)
		return false
	}
	if req.content_length > MAX_BODY {
		send(c, error_reply(413, "too_large", fmt.tprintf("A body may be %d bytes at most.", MAX_BODY)), false)
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
			r := error_reply(405, "method_not_allowed", "The event socket is GET.")
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
		if !login_allowed(g.cfg.behind_proxy, c.remote, http.header(req, "X-Forwarded-Proto")) {
			send(c, error_reply(403, "denied", "A password only goes over HTTPS: through a reverse proxy with TLS (api.behind_proxy), or from this machine."), keep_alive)
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

// match finds the route for a request, and what its parameters were.
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

// route_missing says why no route matched: no such path, or not with
// that method.
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
			r := error_reply(405, "method_not_allowed", fmt.tprintf("%s isn't for %s.", req.path, req.method))
			r.allow = strings.join(allowed[:], ", ", context.temp_allocator)
			return r
		}
	}
	return error_reply(404, "not_found", fmt.tprintf("There's nothing at %s.", req.path))
}

/*
take_token takes the token from `Authorization: Bot <token>` into the
Job, and a turn from its bucket, or says why not.
*/
@(private)
take_token :: proc(g: ^Gateway, j: ^Job, req: ^http.Request) -> (r: Reply, refused: bool) {
	auth := http.header(req, "Authorization")
	scheme, _, token := strings.partition(auth, " ")
	if auth == "" {
		return error_reply(401, "unauthenticated", "A token is needed: Authorization: Bot <token>."), true
	}
	if !strings.equal_fold(scheme, "Bot") || !proto.bot_token_parse(token, &j.key) {
		return error_reply(401, "unauthenticated", "That isn't a token: Authorization: Bot <token>."), true
	}
	return rate_take(g, &j.key)
}

// send writes a reply, and frees its JSON or bytes.
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
			status_line(r.status),
			r.content_type,
			string(r.body),
			keep_alive,
			strings.to_string(extra),
		)
	}
	return http.respond(
		c.sock,
		status_line(r.status),
		"application/json; charset=utf-8",
		r.json,
		keep_alive,
		strings.to_string(extra),
	)
}

@(private)
status_line :: proc(status: int) -> string {
	text: string
	switch status {
	case 200:
		text = "OK"
	case 201:
		text = "Created"
	case 204:
		text = "No Content"
	case 400:
		text = "Bad Request"
	case 401:
		text = "Unauthorized"
	case 403:
		text = "Forbidden"
	case 404:
		text = "Not Found"
	case 405:
		text = "Method Not Allowed"
	case 409:
		text = "Conflict"
	case 410:
		text = "Gone"
	case 411:
		text = "Length Required"
	case 413:
		text = "Content Too Large"
	case 429:
		text = "Too Many Requests"
	case 501:
		text = "Not Implemented"
	case 502:
		text = "Bad Gateway"
	case 503:
		text = "Service Unavailable"
	case:
		text = "Internal Server Error"
	}
	return fmt.tprintf("%d %s", status, text)
}

Error_JSON :: struct {
	error:   string,
	message: string,
}

// json_reply is a reply with `v` as its JSON.
json_reply :: proc(status: int, v: any) -> Reply {
	data, err := json.marshal(v, allocator = context.allocator)
	if err != nil {
		log.errorf("api: could not make JSON of a %v: %v", v.id, err)
		return error_reply(500, "internal", "The answer couldn't be put as JSON.")
	}
	return {status = status, json = string(data)}
}

// empty_reply is a success with nothing to say (204).
empty_reply :: proc() -> Reply {
	return {status = 204}
}

error_reply :: proc(status: int, code, message: string) -> Reply {
	return json_reply(status, Error_JSON{code, message})
}

/*
status_reply is an error for a protocol status that isn't Ok, as the
plan maps them (docs/bot-api, "Errors").
*/
status_reply :: proc(status: proto.Status) -> Reply {
	switch status {
	case .Ok:
		return empty_reply()
	case .Invalid:
		return error_reply(400, "invalid", "The server found something wrong with the request.")
	case .Unauthenticated:
		return error_reply(401, "unauthenticated", "Not logged in.")
	case .Wrong_Password:
		return error_reply(401, "wrong_password", "Wrong username or password.")
	case .Denied:
		return error_reply(403, "denied", "The account may not do that.")
	case .Not_Found:
		return error_reply(404, "not_found", "There's no such thing.")
	case .Conflict:
		return error_reply(409, "conflict", "That's taken, or there already.")
	case .Too_Large:
		return error_reply(413, "too_large", "That's too big.")
	case .Rate_Limited:
		r := error_reply(429, "rate_limited", "Too much at once; try again in a moment.")
		r.retry_after = 1
		return r
	case .Closed:
		return error_reply(410, "closed", "That's closed.")
	case .Unknown_Op:
		return error_reply(501, "unknown_op", "The server is too old for that.")
	case .Reset:
		return error_reply(503, "reset", "The connection to the server started over before it answered; try again.")
	case .Internal:
	}
	return error_reply(500, "internal", "Something went wrong in the server.")
}

// failure_reply is what Jobs waiting on a connection that failed are
// told.
failure_reply :: proc(c: ^lite.Client) -> Reply {
	switch c.failure {
	case .Not_Logged_In:
		return error_reply(401, "unauthenticated", "The server knows no such token (or it was revoked).")
	case .Logged_Out:
		return error_reply(401, "unauthenticated", fmt.tprintf("The token was logged out (%v).", c.logout_reason))
	case .Login_Failed:
		return status_reply(c.login_status)
	case .Refused:
		return error_reply(502, "bad_gateway", "The server wouldn't have the API's connection.")
	case .Wrong_Server_Key:
		return error_reply(502, "bad_gateway", "The server's key isn't the one the API was told to expect.")
	case .Lost:
		return error_reply(503, "unavailable", "The server isn't answering.")
	case .None:
	}
	return error_reply(500, "internal", "The connection failed.")
}

// A connection thread's temp allocations are a request's head, body and
// answer, so it starts small rather than with the default 4 MiB (as the
// relay's, server/relay.odin).
@(private)
CONNECTION_TEMP :: 64 * 1024

/*
serve_connection is an HTTP connection's thread, for a gateway that runs
on its own (src/gateway): the API's requests and nothing else. It closes
the socket and frees `c` when the client goes.
*/
serve_connection :: proc(g: ^Gateway, c: ^http.Conn) {
	temp: runtime.Arena
	_ = runtime.arena_init(&temp, CONNECTION_TEMP, context.allocator)
	context.temp_allocator = runtime.arena_allocator(&temp)
	defer runtime.arena_destroy(&temp)
	defer free(c)
	defer net.close(c.sock)

	head, ok := http.read_head(c)
	if !ok {
		return
	}
	req, parsed := http.parse_request(head)
	if !parsed {
		return
	}
	if !strings.has_prefix(req.path, API_PREFIX) {
		send(c, error_reply(404, "not_found", "Only the API is here, under /api/v1/."), false)
		return
	}
	serve(g, c, req)
}
