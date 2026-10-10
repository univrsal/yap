#+build windows
package server

import "core:time"

// thread_cpu_time is how long the calling thread has been on the CPU.
// Not on Windows: GetThreadTimes counts in clock ticks of ~15.6 ms,
// longer than the turns it would be measuring.
thread_cpu_time :: proc() -> (t: time.Duration, ok: bool) {
	return
}
