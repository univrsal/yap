#+build !wasi
package memtrack

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:sync"

// Memory that C libraries allocate. The allocator can't see it, but it can
// be told about it, in one of two ways:
//
//   - A library that lets the program supply its allocator (SQLite's
//     SQLITE_CONFIG_MALLOC, say) is given c_alloc, c_realloc, c_free and
//     c_size, which take memory from malloc and count it.
//   - A library that allocates by itself and hands the result over (stb_image's
//     pixels) is told about each block with track and untrack.
//
// Both count under a `site` instead of a line of code, because a C library
// has no #caller_location. A site is a Source_Code_Location the caller owns
// and keeps alive, with the library's name as file_path and "C library" as
// procedure; line 0 is shown as "name (procedure)". So a library gets one
// row in the reports, with its total and its peak, but no breakdown by line.

// HEADER is what c_alloc puts in front of an allocation to remember its size.
// It is 16 bytes so that the memory stays aligned like malloc's.
@(private = "file")
HEADER :: 16

@(private = "file")
active :: proc() -> bool {
	return ENABLED && g_tracker.backing.procedure != nil
}

// track counts a block of `size` bytes at `p` that a C library allocated,
// under `site`. Counting it twice, or counting a block that was already
// freed, is harmless (see note_alloc).
track :: proc(site: ^runtime.Source_Code_Location, p: rawptr, size: int) {
	if p == nil || !active() {
		return
	}
	t := &g_tracker
	sync.guard(&t.mutex)
	note_alloc(t, p, size, site^)
}

// untrack stops counting the block at `p`, which is about to be freed. A
// block that was never counted is ignored.
untrack :: proc(p: rawptr) {
	if p == nil || !active() {
		return
	}
	t := &g_tracker
	sync.guard(&t.mutex)
	note_free(t, p)
}

// c_alloc is malloc that counts the block under `site`.
c_alloc :: proc(site: ^runtime.Source_Code_Location, size: int) -> rawptr {
	base := libc.malloc(c.size_t(size + HEADER))
	if base == nil {
		return nil
	}
	(^int)(base)^ = size
	p := rawptr(uintptr(base) + HEADER)
	track(site, p, size)
	return p
}

// c_free is free for what c_alloc and c_realloc returned.
c_free :: proc(p: rawptr) {
	if p == nil {
		return
	}
	untrack(p)
	libc.free(rawptr(uintptr(p) - HEADER))
}

// c_size returns the size c_alloc was asked for.
c_size :: proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return (^int)(uintptr(p) - HEADER)^
}

// c_realloc is realloc for what c_alloc returned. Like realloc's, a size of
// 0 frees the block and a nil `p` allocates.
c_realloc :: proc(site: ^runtime.Source_Code_Location, p: rawptr, size: int) -> rawptr {
	if p == nil {
		return c_alloc(site, size)
	}
	if size == 0 {
		c_free(p)
		return nil
	}
	old := c_size(p)
	untrack(p)
	base := libc.realloc(rawptr(uintptr(p) - HEADER), c.size_t(size + HEADER))
	if base == nil {
		// The block is still where it was.
		track(site, p, old)
		return nil
	}
	(^int)(base)^ = size
	moved := rawptr(uintptr(base) + HEADER)
	track(site, moved, size)
	return moved
}
