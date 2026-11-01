#+build !wasi
package script

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

import log "common:wlog"

// Web requests on a desktop: tinyrequests (yap_requests.c) over WinHTTP, CFNetwork,
// or a libcurl that is loaded when the client starts. Without one (Linux without
// libcurl) there are no requests, and the client says so in its log and on the
// Scripts page, and a script finds out with yap.http_available(). The requests
// are polled from runtime_step; nothing waits and no thread is made.

when ODIN_OS == .Windows {
	@(private = "file")
	REQUESTS_LIB :: "yap_requests.lib"
} else {
	@(private = "file")
	REQUESTS_LIB :: "libyap_requests.a"
}

when !#exists(REQUESTS_LIB) {
	#panic(
		"src/client/script/" +
		REQUESTS_LIB +
		" is missing; build it with build.sh (or build.bat on Windows)",
	)
}

when ODIN_OS == .Windows {
	foreign import requests {REQUESTS_LIB, "system:winhttp.lib"}
} else when ODIN_OS == .Darwin {
	foreign import requests {REQUESTS_LIB, "system:CoreFoundation.framework", "system:CFNetwork.framework"}
} else {
	foreign import requests {REQUESTS_LIB, "system:dl"}
}

@(private = "file")
C_Http_Header :: struct {
	name, value: cstring,
}

// yap_http_result in yap_requests.h
@(private = "file")
C_Http_Result :: struct {
	code:         c.int,
	status:       c.long,
	body:         [^]u8,
	body_len:     c.size_t,
	headers:      [^]C_Http_Header,
	header_count: c.size_t,
	error:        [128]u8,
	priv:         rawptr,
}

@(private = "file")
TR_ERROR_NOMEM :: -2
@(private = "file")
TR_ERROR_TIMEOUT :: -7

@(default_calling_convention = "c", link_prefix = "yap_http_")
foreign requests {
	@(private = "file")
	new :: proc(max_response: c.size_t, backend: ^cstring) -> rawptr ---
	@(private = "file")
	free :: proc(h: rawptr) ---
	@(private = "file")
	begin :: proc(h: rawptr, method, url: cstring, body: rawptr, body_len: c.size_t, headers: [^]cstring, header_count: c.int, timeout_ms: c.long, err: [^]u8, errlen: c.size_t) -> rawptr ---
	@(private = "file")
	poll :: proc(h: rawptr, handle: rawptr, out: ^C_Http_Result) -> c.int ---
	@(private = "file")
	result_free :: proc(r: ^C_Http_Result) ---
	@(private = "file")
	cancel :: proc(h: rawptr, handle: rawptr) ---
}

@(private)
Http_Transport :: struct {
	client:  rawptr, // nil if requests can't be made
	backend: string,
	pending: [dynamic]Net_Request,
}

@(private = "file")
Net_Request :: struct {
	script: ^Script,
	id:     u64,
	handle: rawptr,
}

@(private)
http_start :: proc(rt: ^Runtime) {
	backend: cstring
	rt.http.client = new(MAX_RESPONSE, &backend)
	if rt.http.client == nil {
		when ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
			log.warn("script: libcurl was not found, so scripts can't make web requests (yap.http_get, yap.http_post)")
		} else {
			log.warn("script: web requests are not available, so scripts can't make them")
		}
		return
	}
	rt.http.backend = string(backend)
	log.infof("script: web requests go through %s", backend)
}

@(private)
http_stop :: proc(rt: ^Runtime) {
	for r in rt.http.pending {
		cancel(rt.http.client, r.handle)
	}
	delete(rt.http.pending)
	if rt.http.client != nil {
		free(rt.http.client)
	}
	rt.http = {}
}

@(private)
http_ready :: proc(rt: ^Runtime) -> bool {
	return rt.http.client != nil
}

// runtime_http_status says whether scripts can make web requests, and how (or, if
// they can't, why), for the Scripts page.
runtime_http_status :: proc(rt: ^Runtime) -> (ok: bool, how: string) {
	if rt.http.client != nil {
		return true, rt.http.backend
	}
	when ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		return false, "libcurl was not found"
	} else {
		return false, "not available"
	}
}

@(private)
http_begin :: proc(rt: ^Runtime, s: ^Script, id: u64, req: Http_Request) -> string {
	method, _ := strings.clone_to_cstring(req.method, context.temp_allocator)
	url, _ := strings.clone_to_cstring(req.url, context.temp_allocator)
	pairs := make([]cstring, 2 * len(req.headers), context.temp_allocator)
	for h, i in req.headers {
		pairs[2 * i], _ = strings.clone_to_cstring(h.name, context.temp_allocator)
		pairs[2 * i + 1], _ = strings.clone_to_cstring(h.value, context.temp_allocator)
	}
	err: [128]u8
	handle := begin(
		rt.http.client,
		method,
		url,
		raw_data(req.body) if len(req.body) > 0 else nil,
		c.size_t(len(req.body)),
		raw_data(pairs) if len(pairs) > 0 else nil,
		c.int(len(req.headers)),
		c.long(req.timeout / time.Millisecond),
		&err[0],
		len(err),
	)
	if handle == nil {
		return string(cstring(&err[0]))
	}
	append(&rt.http.pending, Net_Request{script = s, id = id, handle = handle})
	return ""
}

// http_poll gives the scripts the requests that are over.
@(private)
http_poll :: proc(rt: ^Runtime) {
	for i := 0; i < len(rt.http.pending); {
		r := rt.http.pending[i]
		out: C_Http_Result
		if poll(rt.http.client, r.handle, &out) == 0 {
			i += 1
			continue
		}
		response := Http_Response {
			ok     = out.code == 0,
			status = int(out.status),
		}
		if out.code == 0 {
			response.body = string(out.body[:out.body_len])
			headers := make([]Http_Header, int(out.header_count), context.temp_allocator)
			for k in 0 ..< int(out.header_count) {
				headers[k] = {string(out.headers[k].name), string(out.headers[k].value)}
			}
			response.headers = headers
		} else {
			response.error = error_text(int(out.code), string(cstring(&out.error[0])))
		}
		http_finish(r.script, r.id, response)
		result_free(&out)
		unordered_remove(&rt.http.pending, i)
	}
}

@(private = "file")
error_text :: proc(code: int, backend: string) -> string {
	switch code {
	case TR_ERROR_TIMEOUT:
		return "timed out"
	case TR_ERROR_NOMEM:
		return fmt.tprintf("the answer is too large (more than %d KiB)", MAX_RESPONSE / 1024)
	}
	// "libcurl: Could not connect to server": without the name of the library.
	if _, _, rest := strings.partition(backend, ": "); rest != "" {
		return rest
	}
	return backend if backend != "" else "the request failed"
}

// http_cancel_script drops the requests a script still has out, since it is going.
@(private)
http_cancel_script :: proc(rt: ^Runtime, s: ^Script) {
	if rt.http.client == nil {
		return
	}
	for i := 0; i < len(rt.http.pending); {
		if rt.http.pending[i].script == s {
			cancel(rt.http.client, rt.http.pending[i].handle)
			unordered_remove(&rt.http.pending, i)
		} else {
			i += 1
		}
	}
}
