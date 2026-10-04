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

/*
mark_downloaded gives a file we've saved from someone else (a DM's file,
or a message's) the mark a browser gives its downloads: the quarantine
attribute. Gatekeeper then checks an app before it's first opened, and
asks. Nothing comes of it if it can't be set.
*/
mark_downloaded :: proc(path: string) {
	// Flags (0081: downloaded, not yet opened), when, and by what.
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
