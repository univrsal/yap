#+build !windows
package server

import "core:sys/posix"
import "core:time"

// thread_cpu_time returns how much CPU time the calling thread has used.
thread_cpu_time :: proc() -> (t: time.Duration, ok: bool) {
	ts: posix.timespec
	if posix.clock_gettime(.THREAD_CPUTIME_ID, &ts) != .OK {
		return
	}
	return time.Duration(i64(ts.tv_sec) * 1e9 + i64(ts.tv_nsec)), true
}
