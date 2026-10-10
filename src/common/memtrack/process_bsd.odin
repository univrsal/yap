#+build freebsd, openbsd, netbsd
package memtrack

import "core:sys/posix"

// Only the peak, which getrusage has everywhere.

@(private)
_process :: proc() -> (p: Process) {
	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) == .OK {
		p.resident_peak = int(usage.ru_maxrss) * 1024 // kilobytes here
	}
	return
}

@(private)
_release_free :: proc() -> bool {
	return false
}
