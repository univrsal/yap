#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:sync"
import "core:sys/posix"
import "core:time"

import "tui"

// Ctrl+C and the view's wake-up. Both are only flags for now; the event loop
// of the terminal UI will wait on a pipe instead (docs/design/cli-client.md).

@(private = "file")
got_interrupt: bool

interrupt_install :: proc() {
	posix.signal(.SIGINT, interrupt_handler)
	posix.signal(.SIGTERM, interrupt_handler)
}

@(private = "file")
interrupt_handler :: proc "c" (_: posix.Signal) {
	sync.atomic_store(&got_interrupt, true)
	tui.terminal_wake() // the loop is waiting for a key
}

interrupted :: proc() -> bool {
	return sync.atomic_load(&got_interrupt)
}

// wake is called, from the network thread, when the view has changed.
wake :: proc "c" () {}

// wait sleeps for `ms` milliseconds.
wait :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}
