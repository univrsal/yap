#+build !windows
package client

import "core:os"
import "core:thread"

// platform_open_url runs the desktop's URL opener (xdg-open, or open on
// macOS) with the URL as its only argument; no shell is involved.
platform_open_url :: proc(url: string) -> bool {
	opener := "open" when ODIN_OS == .Darwin else "xdg-open"
	p, err := os.process_start({command = {opener, url}})
	if err != nil {
		return false
	}
	// The opener exits once it has passed the URL on; reap it off the UI
	// thread so it doesn't linger as a zombie (waiting also frees the handle).
	thread.create_and_start_with_poly_data(p, proc(p: os.Process) {
		_, _ = os.process_wait(p)
	}, self_cleanup = true)
	return true
}
