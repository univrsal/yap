#+build !wasi
package platform

import "base:runtime"

import "common:memtrack"

// callback_context returns the context for code that the windowing system calls
// directly (input callbacks) rather than through the frame loop. On the desktop
// Odin's defaults work, except that the allocator is the counting one
// (common/memtrack); see web_alloc.odin for why a web build can't use the
// defaults.
callback_context :: proc "contextless" () -> runtime.Context {
	context = runtime.default_context()
	context.allocator = memtrack.allocator()
	return context
}
