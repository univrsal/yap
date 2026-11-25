#+build !wasi
package fetch

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

// Downloads for the client itself (the spell checker's dictionaries,
// ui_spell_download.odin), over the same requests as the scripts'
// (script/http_native.odin): tinyrequests (yap_requests.c, built next to the
// scripts) over WinHTTP, CFNetwork, or a libcurl found when the client runs.
// Each download has a client of its own with its own size limit, and is
// polled; nothing waits and no thread is made.

when ODIN_OS == .Windows {
	@(private = "file")
	REQUESTS_LIB :: "../script/yap_requests.lib"
} else {
	@(private = "file")
	REQUESTS_LIB :: "../script/libyap_requests.a"
}

when !#exists(REQUESTS_LIB) {
	#panic(
		"src/client/script/" +
		REQUESTS_LIB[len("../script/"):] +
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

// yap_http_result in yap_requests.h
@(private = "file")
C_Result :: struct {
	code:         c.int,
	status:       c.long,
	body:         [^]u8,
	body_len:     c.size_t,
	headers:      rawptr,
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
	poll :: proc(h: rawptr, handle: rawptr, out: ^C_Result) -> c.int ---
	@(private = "file")
	result_free :: proc(r: ^C_Result) ---
	@(private = "file")
	cancel :: proc(h: rawptr, handle: rawptr) ---
}

// A download that is on its way.
Download :: struct {
	client: rawptr,
	handle: rawptr,
}

// begin_download starts getting `url`, which may be up to `max_size` bytes. On
// failure, `err` says why (in the temp allocator).
begin_download :: proc(
	url: string,
	max_size: int,
	timeout: time.Duration,
) -> (
	d: Download,
	err: string,
) {
	backend: cstring
	d.client = new(c.size_t(max_size), &backend)
	if d.client == nil {
		when ODIN_OS == .Windows || ODIN_OS == .Darwin {
			return {}, "web requests are not available"
		} else {
			return {}, "libcurl was not found"
		}
	}
	curl := strings.clone_to_cstring(url, context.temp_allocator)
	buf: [128]u8
	d.handle = begin(
		d.client,
		"GET",
		curl,
		nil,
		0,
		nil,
		0,
		c.long(timeout / time.Millisecond),
		&buf[0],
		len(buf),
	)
	if d.handle == nil {
		free(d.client)
		return {}, strings.clone(string(cstring(&buf[0])), context.temp_allocator)
	}
	return d, ""
}

// poll_download is whether the download is over, and then what came (in
// `allocator`) or why nothing did (in the temp allocator). An answer other
// than 200 is a failure. `d` is done with once it is over.
poll_download :: proc(
	d: ^Download,
	allocator := context.allocator,
) -> (
	done: bool,
	body: []u8,
	err: string,
) {
	if d.client == nil {
		return true, nil, "it wasn't started"
	}
	out: C_Result
	if poll(d.client, d.handle, &out) == 0 {
		return false, nil, ""
	}
	switch {
	case out.code == TR_ERROR_NOMEM:
		err = "the file is larger than expected"
	case out.code == TR_ERROR_TIMEOUT:
		err = "it timed out"
	case out.code != 0:
		// "libcurl: Could not resolve host": without the name of the library.
		e := string(cstring(&out.error[0]))
		if _, _, rest := strings.partition(e, ": "); rest != "" {
			e = rest
		}
		err = strings.clone(e if e != "" else "the request failed", context.temp_allocator)
	case out.status != 200:
		err = fmt.tprintf("the server answered %d", out.status)
	case:
		body = make([]u8, int(out.body_len), allocator)
		copy(body, out.body[:out.body_len])
	}
	result_free(&out)
	free(d.client)
	d^ = {}
	return true, body, err
}

// cancel_download gives up on a download that isn't over (or lets go of one
// that is).
cancel_download :: proc(d: ^Download) {
	if d.client != nil {
		cancel(d.client, d.handle)
		free(d.client)
	}
	d^ = {}
}
