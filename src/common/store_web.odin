#+build wasi
package common

import log "wlog"
import "core:strings"

/*
In a browser the same named blobs live in the page's local storage,
which is per site and survives a reload. It can be switched off or
full, so a write that doesn't take is reported rather than assumed.

The four lines of JavaScript behind these sit with the rest of the
page's glue (see web/shell.c).
*/

@(default_calling_convention = "c")
foreign _ {
	yap_store_exists :: proc(name: cstring) -> i32 ---
	yap_store_read :: proc(name: cstring, buf: [^]u8, buf_size: i32) -> i32 ---
	yap_store_write :: proc(name: cstring, data: [^]u8, size: i32) -> i32 ---
}

store_exists :: proc(name: string) -> bool {
	return yap_store_exists(temp_cstring(name)) != 0
}

store_read :: proc(name: string, allocator := context.allocator) -> (text: string, ok: bool) {
	buf: [STORE_MAX_SIZE]u8
	n := yap_store_read(temp_cstring(name), raw_data(buf[:]), len(buf))
	if n < 0 {
		return "", false
	}
	return strings.clone(string(buf[:n]), allocator), true
}

// Everything a page stores is as private as the page itself, so there
// is nothing for `private` to do here.
store_write :: proc(name: string, text: string, private := false) -> bool {
	if yap_store_write(temp_cstring(name), raw_data(text), i32(len(text))) == 0 {
		log.errorf("failed to store %s (is local storage full or switched off?)", name)
		return false
	}
	return true
}

@(private = "file")
temp_cstring :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
