#+build windows
package server

import "core:time"

// thread_cpu_time returns how much CPU time the calling thread has used.
// This is not supported on Windows because GetThreadTimes counts in clock
// ticks of about 15.6 ms, which is longer than the turns being measured.
thread_cpu_time :: proc() -> (t: time.Duration, ok: bool) {
	return
}
