#+build wasi
package client

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// window.open, in a new tab (see web/shell.c).
	yap_open_url :: proc(url: cstring) -> i32 ---
}

// A link in the chat opens in a new tab. links.odin has already checked
// it's a web address before it gets here.
platform_open_url :: proc(url: string) -> bool {
	return yap_open_url(strings.clone_to_cstring(url, context.temp_allocator)) != 0
}
