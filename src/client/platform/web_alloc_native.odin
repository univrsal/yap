#+build !wasi
package platform

import "base:runtime"

import "common:memtrack"

// callback_context is the context for code the windowing system calls
// on its own - input callbacks - rather than through the frame loop. On
// a desktop Odin's own defaults do, but for the allocator that counts
// (common/memtrack); see web_alloc.odin for why a web build can't use
// them.
callback_context :: proc "contextless" () -> runtime.Context {
	context = runtime.default_context()
	context.allocator = memtrack.allocator()
	return context
}
