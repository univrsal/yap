package conn

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"

foreign import system "system:System.framework"

@(default_calling_convention = "c")
foreign system {
	@(private = "file")
	setxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> c.int ---
}

// mark_downloaded gives a file we saved from someone else (an attachment of a
// DM or of a message) the quarantine attribute that browsers set on their
// downloads. Gatekeeper then checks an app and asks before it is opened for
// the first time. Failing to set the attribute is ignored.
mark_downloaded :: proc(path: string) {
	// The value is: flags (0081 means downloaded and not yet opened), timestamp, and app name.
	value := fmt.tprintf("0081;%08x;yap;", time.time_to_unix(time.now()))
	setxattr(
		strings.clone_to_cstring(path, context.temp_allocator),
		"com.apple.quarantine",
		raw_data(value),
		c.size_t(len(value)),
		0,
		0,
	)
}
