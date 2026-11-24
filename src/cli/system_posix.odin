#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:strings"
import "core:sys/posix"

// The parts of the program that are the system's: signals and stderr.

@(private)
interrupt_install_os :: proc() {
	posix.signal(.SIGINT, interrupt_handler)
	posix.signal(.SIGTERM, interrupt_handler)
}

@(private = "file")
interrupt_handler :: proc "c" (_: posix.Signal) {
	interrupt_set()
}

// redirect_stderr sends what is written to stderr to the file (appending), or
// nowhere if there is none.
@(private)
redirect_stderr :: proc(path: string) {
	target := strings.clone_to_cstring(path if path != "" else "/dev/null", context.temp_allocator)
	fd := posix.open(target, {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR})
	if fd >= 0 {
		posix.dup2(fd, posix.STDERR_FILENO)
		posix.close(fd)
	}
}
