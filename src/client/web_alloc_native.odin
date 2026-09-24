#+build !wasi
package client

import "base:runtime"

// callback_context is the context for code the windowing system calls
// on its own - input callbacks - rather than through the frame loop. On
// a desktop Odin's own defaults do; see web_alloc.odin for why a web
// build can't use them.
callback_context :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}
