#+build wasi
package platform

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// The browser and system as the page sees them, "Firefox 128 on
	// Windows" (see web/shell.c); the length written, 0 if unknown.
	yap_agent :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

// agent is what to tell the server this client is, for the account's
// list of devices. In the temp allocator.
agent :: proc() -> string {
	buf: [64]u8
	n := int(yap_agent(raw_data(buf[:]), i32(len(buf))))
	if n <= 0 || n >= len(buf) {
		return "web"
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}
