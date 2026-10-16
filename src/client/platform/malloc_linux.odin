#+build linux
package platform

import "core:c"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	mallopt :: proc(param: c.int, value: c.int) -> c.int ---
}

@(private = "file")
M_MMAP_THRESHOLD :: -3

// The size from which malloc gives a buffer a mapping of its own, which goes
// back to the system when it is freed.
@(private = "file")
MMAP_THRESHOLD :: 256 * 1024

// malloc_tune keeps glibc's malloc from holding on to big buffers once they are
// freed (decoded pictures, the emoji sheet). glibc raises its mmap threshold
// after the first big buffer is freed, so that later ones come from its arenas
// and stay in RAM after they are freed: 12 MB after start and over 100 MB
// after looking at some photos (see misc/memory). A fixed threshold also turns
// that off. Call before anything allocates. musl ignores it, and doesn't need it.
malloc_tune :: proc() {
	mallopt(M_MMAP_THRESHOLD, MMAP_THRESHOLD)
}
