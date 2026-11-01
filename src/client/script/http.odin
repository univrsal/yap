package script

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"

// yap.http_get(url, fn[, options]) and yap.http_post(url, body, fn[, options]):
// a request that is made while the script goes on, and `fn(answer)` is called
// when it has been answered or has failed:
//
//	answer = { ok = true, status = 200, body = "...", headers = { ["content-type"] = "..." } }
//	answer = { ok = false, error = "timed out" }       -- no answer was got
//
// `ok` is whether there was an answer at all: a 404 is `ok` with status 404.
// options: { headers = { Name = "value" }, content_type = "...", timeout = seconds }.
//
// Doing the request is the host's (runtime.odin; http_native.odin has libcurl,
// WinHTTP or CFNetwork do it, http_web.odin the browser): this is what a script
// may ask for and the bookkeeping. It needs the `net` permission, and when
// requests can't be made at all (no libcurl) fn is still called, with ok = false.

MAX_URL :: 2048
MAX_REQUEST_BODY :: 256 * 1024
MAX_RESPONSE :: 1024 * 1024
MAX_REQUEST_HEADERS :: 16
MAX_HEADER_NAME :: 64
MAX_HEADER_VALUE :: 1024
MAX_PENDING_REQUESTS :: 4
MAX_REQUESTS_PER_MINUTE :: 30
DEFAULT_REQUEST_TIME :: 10 * time.Second
MAX_REQUEST_TIME :: 30 * time.Second

Http_Header :: struct {
	name, value: string,
}

// What the host is asked to do. Its strings are in the temp allocator, for the
// call.
Http_Request :: struct {
	method:  string, // "GET" or "POST"
	url:     string,
	body:    string,
	headers: []Http_Header,
	timeout: time.Duration,
}

// What the host got, for http_finish; the host frees it.
Http_Response :: struct {
	ok:      bool, // there was an answer
	status:  int,
	body:    string,
	headers: []Http_Header,
	error:   string,
}

// A request that has not been answered.
@(private)
Pending_Request :: struct {
	id:     u64,
	fn:     c.int, // the function to call, a reference in the script's Lua state
	server: Server_Id,
}

// An answer that has to be given to its function, at the start of the next step.
@(private)
Completion :: struct {
	fn:       c.int,
	server:   Server_Id,
	response: Http_Response, // owned
}

@(private)
response_destroy :: proc(r: ^Http_Response, allocator: runtime.Allocator) {
	delete(r.body, allocator)
	delete(r.error, allocator)
	for h in r.headers {
		delete(h.name, allocator)
		delete(h.value, allocator)
	}
	delete(r.headers, allocator)
	r^ = {}
}

// http_finish gives a script what came of its request `id`. The response is
// copied; the host keeps (and frees) its own.
http_finish :: proc(s: ^Script, id: u64, r: Http_Response) {
	for p, i in s.requests {
		if p.id != id {
			continue
		}
		c := Completion {
			fn     = p.fn,
			server = p.server,
		}
		c.response = {
			ok     = r.ok,
			status = r.status,
			body   = strings.clone(r.body, s.allocator),
			error  = strings.clone(r.error, s.allocator),
		}
		c.response.headers = make([]Http_Header, len(r.headers), s.allocator)
		for h, k in r.headers {
			c.response.headers[k] = {strings.clone(h.name, s.allocator), strings.clone(h.value, s.allocator)}
		}
		append(&s.completions, c)
		unordered_remove(&s.requests, i)
		return
	}
}

// completions_deliver calls the functions of the requests that have been
// answered. Between the steps of the handlers, not inside a call of the host.
@(private)
completions_deliver :: proc(s: ^Script) {
	if len(s.completions) == 0 {
		return
	}
	list := s.completions
	s.completions = make([dynamic]Completion, s.allocator)
	for &c in list {
		pairs := make([dynamic]Pair, 0, 6, context.temp_allocator)
		append(&pairs, Pair{"ok", c.response.ok})
		if c.response.status != 0 {
			append(&pairs, Pair{"status", i64(c.response.status)})
		}
		if c.response.ok {
			append(&pairs, Pair{"body", c.response.body})
		}
		if c.response.error != "" {
			append(&pairs, Pair{"error", c.response.error})
		}
		// Header names in lower case, as HTTP means them; one that comes twice is joined.
		headers := make([dynamic]Pair, context.temp_allocator)
		for h in c.response.headers {
			name := strings.to_lower(h.name, context.temp_allocator)
			found := false
			for &p in headers {
				if p.key == name {
					p.value = strings.concatenate({p.value.(string), ", ", h.value}, context.temp_allocator)
					found = true
				}
			}
			if !found {
				append(&headers, Pair{name, h.value})
			}
		}
		append(&pairs, Pair{"headers", Map(headers[:])})
		call_function(s, c.fn, "http", Map(pairs[:]), c.server)
		release(s.state, c.fn)
		response_destroy(&c.response, s.allocator)
	}
	delete(list)
}

// call_function queues a call of the function that `fn` refers to (a reference
// that spawn_ref takes).
@(private)
call_function :: proc(s: ^Script, fn: c.int, name: string, arg: Value, server: Server_Id) {
	buf: [ERROR_LEN]u8
	t := Task {
		name   = name,
		server = server,
	}
	arena := runtime.arena_allocator(&s.scratch)
	free_all(arena)
	defer free_all(arena)
	value := to_c(arg, arena)
	status := spawn_ref(s.state, fn, &value, &t.thread, &t.ref, &t.nargs, &buf[0], len(buf))
	_, _ = queue(s, &t, status, buf[:])
}

// An http or https address, nothing else, with something after the scheme and
// no spaces or control characters.
@(private)
url_ok :: proc(url: string) -> bool {
	rest: string
	switch {
	case len(url) > 8 && strings.equal_fold(url[:8], "https://"):
		rest = url[8:]
	case len(url) > 7 && strings.equal_fold(url[:7], "http://"):
		rest = url[7:]
	case:
		return false
	}
	for r in url {
		if r <= ' ' || r == 0x7f {
			return false
		}
	}
	return rest != "" && rest[0] != '/' && rest[0] != ':'
}

@(private)
header_name_ok :: proc(name: string) -> bool {
	if name == "" || len(name) > MAX_HEADER_NAME {
		return false
	}
	for r in name {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		case:
			return false
		}
	}
	// What the library sets itself, and what changes how the message is framed.
	switch strings.to_lower(name, context.temp_allocator) {
	case "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "expect":
		return false
	}
	return true
}

@(private)
header_value_ok :: proc(value: string) -> bool {
	if len(value) > MAX_HEADER_VALUE {
		return false
	}
	for r in value {
		if r == '\r' || r == '\n' || r == 0 {
			return false
		}
	}
	return true
}

// request_make reads the arguments of yap.http_get (which has no body) and
// yap.http_post: the address, the body, the function and the options.
@(private)
request_make :: proc(
	s: ^Script,
	a: Args,
	post: bool,
) -> (
	req: Http_Request,
	fn: Function,
	fn_index: int,
	err: Maybe(string),
) {
	index := 0
	req.method = "POST" if post else "GET"
	req.url = arg_string(a, index, MAX_URL) or_return
	if !url_ok(req.url) {
		err = error_of("yap.%s: %q is not an http or https address", a.name, req.url)
		return
	}
	index += 1
	if post {
		req.body = arg_string(a, index, MAX_REQUEST_BODY, true) or_return
		index += 1
	}
	if index >= len(a.values) {
		err = error_of("yap.%s: the function to call with the answer is missing", a.name)
		return
	}
	f, is_fn := a.values[index].(Function)
	if !is_fn {
		err = error_of("yap.%s: the function to call with the answer is missing", a.name)
		return
	}
	fn, fn_index = f, index
	index += 1
	req.timeout = DEFAULT_REQUEST_TIME

	if index < len(a.values) && a.values[index] != nil {
		options, is_map := a.values[index].(Map)
		if _, is_list := a.values[index].(List); is_list && len(a.values[index].(List)) == 0 {
			is_map = true // {} reads as a list
		}
		if !is_map {
			err = error_of("yap.%s: the options must be a table", a.name)
			return
		}
		headers := make([dynamic]Http_Header, context.temp_allocator)
		for p in options {
			switch p.key {
			case "timeout":
				seconds, is_number := number_of(p.value)
				if !is_number || seconds <= 0 {
					err = error_of("yap.%s: timeout is a number of seconds", a.name)
					return
				}
				req.timeout = min(time.Duration(seconds * f64(time.Second)), MAX_REQUEST_TIME)
			case "content_type":
				text, is_text := p.value.(string)
				if !is_text || !header_value_ok(text) {
					err = error_of("yap.%s: content_type is not valid", a.name)
					return
				}
				append(&headers, Http_Header{"Content-Type", text})
			case "headers":
				given, given_map := p.value.(Map)
				if !given_map {
					if l, is_list := p.value.(List); !is_list || len(l) != 0 {
						err = error_of("yap.%s: headers must be a table of names and values", a.name)
						return
					}
				}
				for h in given {
					value, is_text := h.value.(string)
					if !is_text || !header_name_ok(h.key) || !header_value_ok(value) {
						err = error_of("yap.%s: the header %q is not allowed", a.name, h.key)
						return
					}
					append(&headers, Http_Header{h.key, value})
				}
			case:
				err = error_of("yap.%s: there is no option %q", a.name, p.key)
				return
			}
		}
		if len(headers) > MAX_REQUEST_HEADERS {
			err = error_of("yap.%s: at most %d headers", a.name, MAX_REQUEST_HEADERS)
			return
		}
		req.headers = headers[:]
	}
	return
}

// request_start does what yap.http_get and yap.http_post ask: checks the limits,
// and hands the request to the host, or has the function told at once that there
// is none. The function is kept (by the caller) in either case.
@(private)
request_start :: proc(s: ^Script, req: Http_Request, fn: Function, server: Server_Id) -> (err: Maybe(string)) {
	if len(s.requests) >= MAX_PENDING_REQUESTS {
		return error_of("yap.http: at most %d requests at once", MAX_PENDING_REQUESTS)
	}
	now := time.tick_now()
	if s.http_count == 0 || time.tick_diff(s.http_window, now) > time.Minute {
		s.http_window, s.http_count = now, 0
	}
	if s.http_count >= MAX_REQUESTS_PER_MINUTE {
		return error_of("yap.http: at most %d requests in a minute", MAX_REQUESTS_PER_MINUTE)
	}
	s.http_count += 1
	s.next_request += 1
	id := s.next_request
	append(&s.requests, Pending_Request{id = id, fn = c.int(fn), server = server})
	fail := ""
	switch {
	case s.host == nil || s.host.http_begin == nil || s.host.http_available == nil || !s.host.http_available(s.host):
		fail = "requests can't be made here (no libcurl was found)"
	case true:
		fail = s.host.http_begin(s.host, s, id, req)
	}
	if fail != "" {
		http_finish(s, id, Http_Response{error = fail})
	}
	return nil
}
