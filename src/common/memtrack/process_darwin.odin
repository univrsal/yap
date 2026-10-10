#+build darwin
package memtrack

import "core:c"
import "core:sys/darwin"
import "core:sys/posix"

// The resident size and footprint from proc_pid_rusage (the footprint is
// what Activity Monitor calls Memory), the heap from malloc's zones.

foreign import libsystem "system:System"

@(private = "file")
Malloc_Statistics :: struct {
	blocks_in_use:   c.uint,
	size_in_use:     c.size_t,
	max_size_in_use: c.size_t,
	size_allocated:  c.size_t,
}

@(private = "file", default_calling_convention = "c")
foreign libsystem {
	// nil: all the zones.
	malloc_zone_statistics :: proc(zone: rawptr, stats: ^Malloc_Statistics) ---
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: c.size_t) -> c.size_t ---
}

@(private)
_process :: proc() -> (p: Process) {
	info: darwin.rusage_info_v0
	if darwin.proc_pid_rusage(posix.getpid(), .V0, &info) == 0 {
		p.resident = int(info.ri_resident_size)
		p.private = int(info.ri_phys_footprint)
	}
	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) == .OK {
		p.resident_peak = int(usage.ru_maxrss) // bytes, on macOS
	}
	stats: Malloc_Statistics
	malloc_zone_statistics(nil, &stats)
	p.heap_known = true
	p.heap_in_use = int(stats.size_in_use)
	p.heap_free = max(int(stats.size_allocated) - int(stats.size_in_use), 0)
	return
}

@(private)
_release_free :: proc() -> bool {
	malloc_zone_pressure_relief(nil, 0)
	return true
}
