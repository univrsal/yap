#+build windows
package main

import "core:c/libc"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	SetStdHandle :: proc(nStdHandle: win.DWORD, hHandle: win.HANDLE) -> win.BOOL ---
}

// The parts of the program that are the system's: the console's Ctrl+C and
// close, and stderr.

@(private)
interrupt_install_os :: proc() {
	win.SetConsoleCtrlHandler(interrupt_handler, true)
}

// interrupt_handler runs on a thread of its own. When the console window is
// closed (or the user logs off) the process is ended as soon as this returns, so
// it waits a little to let the main loop give the console back and close the
// connections; Windows ends it after a few seconds anyway.
@(private = "file")
interrupt_handler :: proc "system" (ctrl: win.DWORD) -> win.BOOL {
	interrupt_set()
	switch ctrl {
	case win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		win.Sleep(3000)
	}
	return true
}

// redirect_stderr sends what is written to stderr to the file (appending), or
// nowhere if there is none: both the C runtime's stderr, which the C libraries
// write to, and the process's standard error handle.
@(private)
redirect_stderr :: proc(path: string) {
	target := strings.clone_to_cstring(path if path != "" else "NUL", context.temp_allocator)
	libc.freopen(target, "a", libc.stderr)
	h := win.CreateFileW(
		win.utf8_to_wstring(path if path != "" else "NUL", context.temp_allocator),
		win.FILE_APPEND_DATA,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		nil,
		win.OPEN_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h != win.INVALID_HANDLE_VALUE {
		SetStdHandle(win.STD_ERROR_HANDLE, h)
	}
}
