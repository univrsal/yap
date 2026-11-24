package main

import "core:sync"
import "core:time"

import "tui"

// Ctrl+C and the view's wake-up. Both are only flags for now; the event loop
// of the terminal UI will wait on a pipe instead (docs/design/cli-client.md).
// In the terminal UI Ctrl+C is a key (the terminal is raw); this is for -print,
// and for being told to stop (SIGTERM, or the console window closing).

@(private = "file")
got_interrupt: bool

interrupt_install :: proc() {
	interrupt_install_os()
}

@(private)
interrupt_set :: proc "contextless" () {
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
