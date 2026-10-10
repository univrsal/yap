#+build !wasi
package memtrack

import "base:runtime"
import "core:strings"
import "core:testing"

@(test)
counts_by_line :: proc(t: ^testing.T) {
	when !ENABLED {
		return
	}
	a := init(runtime.heap_allocator())
	// The temp allocator's first block is counted too, once it's made.
	_ = sites()
	before := totals()

	small := make([]u8, 100, a)
	big := make([]u8, 1000, a)
	after := totals()
	testing.expect_value(t, after.live - before.live, 1100)
	testing.expect_value(t, after.count - before.count, 2)

	// A resize moves what's counted to its new size.
	grown := make([dynamic]u8, 0, 10, a)
	resize(&grown, 5000)
	testing.expect_value(t, totals().live - before.live, 1100 + cap(grown))

	// Freed is no longer live, and freeing what wasn't counted is harmless.
	delete(big, a)
	delete(grown)
	stray := make([]u8, 64, runtime.heap_allocator())
	delete(stray, a)
	testing.expect_value(t, totals().live - before.live, 100)

	this_file := false
	for f in by_file(sites()) {
		if strings.has_suffix(f.file, "memtrack_test.odin") {
			this_file = true
			testing.expect_value(t, f.live, 100)
		}
	}
	testing.expect(t, this_file)
	delete(small, a)
	testing.expect_value(t, totals().live, before.live)

	text := report()
	defer delete(text)
	testing.expect(t, strings.contains(text, "# Live, by file"))
}

@(test)
short_paths :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		short_path("/x/yap/src/client/conn/messages.odin"),
		"conn/messages.odin",
	)
	testing.expect_value(t, short_path("/x/yap/src/client/ui.odin"), "client/ui.odin")
	testing.expect_value(
		t,
		short_path("/usr/lib/odin/core/strings/builder.odin"),
		"core/strings/builder.odin",
	)
	testing.expect_value(t, short_path("temp allocator"), "temp allocator")
}
