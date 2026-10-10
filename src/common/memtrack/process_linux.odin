#+build linux
package memtrack

import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

/*
Resident sizes from /proc/self/status, and the heap from glibc's
mallinfo2, summed over all its arenas (each thread that allocates may
get an arena of its own, and what's freed in one stays there). It's
looked up rather than linked, as musl has neither it nor malloc_trim.
*/

@(private = "file")
Mallinfo2 :: struct {
	arena:    c.size_t, // from the OS with brk, and the threads' arenas
	ordblks:  c.size_t,
	smblks:   c.size_t,
	hblks:    c.size_t,
	hblkhd:   c.size_t, // in mmapped chunks: the big allocations
	usmblks:  c.size_t,
	fsmblks:  c.size_t,
	uordblks: c.size_t, // in use, of arena
	fordblks: c.size_t, // free, of arena
	keepcost: c.size_t,
}

@(private = "file")
Glibc :: struct {
	looked:      bool,
	mallinfo2:   proc "c" () -> Mallinfo2,
	malloc_trim: proc "c" (pad: c.size_t) -> c.int,
}

@(private = "file")
g_glibc: Glibc

@(private = "file")
glibc :: proc() -> ^Glibc {
	g := &g_glibc
	if !g.looked {
		g.looked = true
		if self := posix.dlopen(nil, {.LAZY}); self != nil {
			g.mallinfo2 = auto_cast posix.dlsym(self, "mallinfo2")
			g.malloc_trim = auto_cast posix.dlsym(self, "malloc_trim")
		}
	}
	return g
}

@(private)
_process :: proc() -> (p: Process) {
	if text, err := os.read_entire_file("/proc/self/status", context.temp_allocator); err == nil {
		rest := string(text)
		for line in strings.split_lines_iterator(&rest) {
			name, _, value := strings.partition(line, ":")
			switch name {
			case "VmRSS":
				p.resident = kb_value(value)
			case "VmHWM":
				p.resident_peak = kb_value(value)
			}
		}
	}
	if g := glibc(); g.mallinfo2 != nil {
		info := g.mallinfo2()
		p.heap_known = true
		p.heap_in_use = int(info.uordblks + info.hblkhd)
		p.heap_free = int(info.fordblks)
	}
	return
}

// kb_value reads "    1234 kB".
@(private = "file")
kb_value :: proc(s: string) -> int {
	n, _ := strconv.parse_int(strings.trim_suffix(strings.trim_space(s), " kB"), 10)
	return n * 1024
}

@(private)
_release_free :: proc() -> bool {
	g := glibc()
	if g.malloc_trim == nil {
		return false
	}
	g.malloc_trim(0)
	return true
}
