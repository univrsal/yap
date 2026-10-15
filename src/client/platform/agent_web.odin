#+build wasi
package platform

import "core:strings"

@(default_calling_convention = "c")
foreign _ {
	// Writes the browser and system as the page sees them, e.g. "Firefox 128 on
	// Windows" (see web/shell.c). Returns the length written, or 0 if unknown.
	yap_agent :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

// agent returns the description of this client that is sent to the server for
// the account's list of devices. The string is allocated in the temp allocator.
agent :: proc() -> string {
	buf: [64]u8
	n := int(yap_agent(raw_data(buf[:]), i32(len(buf))))
	if n <= 0 || n >= len(buf) {
		return "web"
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}
