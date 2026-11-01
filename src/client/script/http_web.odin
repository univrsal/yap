#+build wasi
package script

import "core:c"
import "core:strings"

import "client:platform"

// Web requests in a browser: the page's fetch (web/http.js). The browser's rules
// apply (docs/design/scripting.md): an answer can only be read from a server that
// allows it, no cookies are sent, and an https page can't ask for http. The page
// tells of an answer through web_http_done, outside the frame loop, so it is
// only noted there, and given to the script by the next runtime_step.

@(default_calling_convention = "c")
foreign _ {
	yap_http_fetch :: proc(id: c.int, method, url: cstring, body: [^]u8, body_len: c.int, headers: cstring, timeout_ms: c.int, max_response: c.int) ---
	yap_http_abort :: proc(id: c.int) ---
}

@(private)
Http_Transport :: struct {
	pending: [dynamic]Web_Request,
	done:    [dynamic]Web_Done,
	next:    c.int,
}

@(private = "file")
Web_Request :: struct {
	script:  ^Script,
	id:      u64, // the script's
	page_id: c.int, // the page's
}

// What the page said about a request that is over (owned).
@(private = "file")
Web_Done :: struct {
	page_id: c.int,
	status:  int,
	body:    string,
	headers: string, // "name: value" lines
	error:   string,
}

// The runtime the page's answers are for (there is one per page).
@(private = "file")
g_runtime: ^Runtime

@(private)
http_start :: proc(rt: ^Runtime) {
	g_runtime = rt
}

@(private)
http_stop :: proc(rt: ^Runtime) {
	for r in rt.http.pending {
		yap_http_abort(r.page_id)
	}
	delete(rt.http.pending)
	for &d in rt.http.done {
		done_destroy(&d)
	}
	delete(rt.http.done)
	rt.http = {}
	g_runtime = nil
}

@(private = "file")
done_destroy :: proc(d: ^Web_Done) {
	delete(d.body)
	delete(d.headers)
	delete(d.error)
}

@(private)
http_ready :: proc(rt: ^Runtime) -> bool {
	return true
}

runtime_http_status :: proc(rt: ^Runtime) -> (ok: bool, how: string) {
	return true, "the browser's fetch"
}

@(private)
http_begin :: proc(rt: ^Runtime, s: ^Script, id: u64, req: Http_Request) -> string {
	method, _ := strings.clone_to_cstring(req.method, context.temp_allocator)
	url, _ := strings.clone_to_cstring(req.url, context.temp_allocator)
	lines := strings.builder_make(context.temp_allocator)
	for h in req.headers {
		strings.write_string(&lines, h.name)
		strings.write_string(&lines, ": ")
		strings.write_string(&lines, h.value)
		strings.write_byte(&lines, '\n')
	}
	headers, _ := strings.clone_to_cstring(strings.to_string(lines), context.temp_allocator)
	rt.http.next += 1
	page_id := rt.http.next
	append(&rt.http.pending, Web_Request{script = s, id = id, page_id = page_id})
	yap_http_fetch(
		page_id,
		method,
		url,
		raw_data(req.body),
		c.int(len(req.body)),
		headers,
		c.int(req.timeout / 1_000_000),
		c.int(MAX_RESPONSE),
	)
	return ""
}

// web_http_done is what the page calls when a request is over.
@(export)
web_http_done :: proc "c" (
	id: c.int,
	status: c.int,
	body: [^]u8,
	body_len: c.int,
	headers: [^]u8,
	headers_len: c.int,
	error: [^]u8,
	error_len: c.int,
) {
	context = platform.callback_context()
	if g_runtime == nil {
		return
	}
	append(
		&g_runtime.http.done,
		Web_Done {
			page_id = id,
			status = int(status),
			body = strings.clone(string(body[:max(body_len, 0)])),
			headers = strings.clone(string(headers[:max(headers_len, 0)])),
			error = strings.clone(string(error[:max(error_len, 0)])),
		},
	)
}

// http_poll gives the scripts the requests that are over.
@(private)
http_poll :: proc(rt: ^Runtime) {
	for &d in rt.http.done {
		for r, i in rt.http.pending {
			if r.page_id != d.page_id {
				continue
			}
			response := Http_Response {
				ok     = d.error == "",
				status = d.status,
				error  = d.error,
			}
			if response.ok {
				response.body = d.body
				lines := strings.split_lines(d.headers, context.temp_allocator)
				headers := make([dynamic]Http_Header, context.temp_allocator)
				for line in lines {
					if name, _, value := strings.partition(line, ": "); name != "" && value != "" {
						append(&headers, Http_Header{name, value})
					}
				}
				response.headers = headers[:]
			}
			http_finish(r.script, r.id, response)
			unordered_remove(&rt.http.pending, i)
			break
		}
		done_destroy(&d)
	}
	clear(&rt.http.done)
}

// http_cancel_script drops the requests a script still has out, since it is going.
@(private)
http_cancel_script :: proc(rt: ^Runtime, s: ^Script) {
	for i := 0; i < len(rt.http.pending); {
		if rt.http.pending[i].script == s {
			yap_http_abort(rt.http.pending[i].page_id)
			unordered_remove(&rt.http.pending, i)
		} else {
			i += 1
		}
	}
}
