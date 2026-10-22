#+build wasi
package platform

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// The browser's language (see web/shell.c).
	yap_locale :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

// locale_name returns the browser's language ("en-US", "de"), or "" if it
// doesn't say. In the temp allocator.
locale_name :: proc() -> string {
	buf: [64]u8
	n := yap_locale(raw_data(buf[:]), len(buf))
	if n <= 0 {
		return ""
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}
