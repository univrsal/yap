#+build wasi
package platform

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// Opens the URL in a new tab with window.open (see web/shell.c).
	yap_open_url :: proc(url: cstring) -> i32 ---
}

// platform_open_url opens a chat link in a new tab. links.odin has already
// checked that it's a web address before it gets here.
platform_open_url :: proc(url: string) -> bool {
	return yap_open_url(strings.clone_to_cstring(url, context.temp_allocator)) != 0
}
