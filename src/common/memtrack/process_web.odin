#+build wasi
package memtrack

import "base:intrinsics"
import "core:c"

/*
A page's memory is the wasm linear memory, which only grows; inside it
is emscripten's malloc (dlmalloc), which says what of it is in use
(web/shell.c asks it).
*/

@(private = "file", default_calling_convention = "c")
foreign _ {
	yap_malloc_stats :: proc(in_use: ^c.int, free_bytes: ^c.int) ---
	malloc_trim :: proc(pad: c.size_t) -> c.int ---
}

@(private)
_process :: proc() -> (p: Process) {
	p.wasm_memory = int(intrinsics.wasm_memory_size(0)) * 65536
	p.resident = p.wasm_memory
	in_use, free_bytes: c.int
	yap_malloc_stats(&in_use, &free_bytes)
	p.heap_known = true
	p.heap_in_use = int(in_use)
	p.heap_free = int(free_bytes)
	return
}

@(private)
_release_free :: proc() -> bool {
	// The memory stays the page's; this only tidies dlmalloc's top.
	malloc_trim(0)
	return true
}
