#+build !windows
#+build !wasi
package render

import "core:strings"
import "core:sys/posix"

// Mapping the system's font files (sysfont.odin) on macOS, Linux and the
// BSDs.

// map_font_file maps a file into memory, read-only.
@(private)
map_font_file :: proc(path: string) -> (data: []u8, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {})
	if fd < 0 {
		return
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 || st.st_size > 1 << 31 {
		return
	}
	size := uint(st.st_size)
	p := posix.mmap(nil, size, {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED {
		return
	}
	return ([^]u8)(p)[:size], true
}

@(private)
unmap_font_file :: proc(data: []u8) {
	posix.munmap(raw_data(data), uint(len(data)))
}
