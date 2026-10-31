// Lua for the client's scripts, as built by build.sh / build.bat from
// yap_lua.c (the language plus the libraries a script may use; no io, os,
// package or debug). This is everything Odin needs to know about it: the
// Lua API itself is only used from C, so that a Lua error (which is a
// longjmp) never goes through an Odin frame, which matters on the web.
package script

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_lua.lib"
} else {
	@(private)
	LIB :: "libyap_lua.a"
}

when ODIN_OS != .WASI {
	when !#exists(LIB) {
		#panic(
			"src/client/script/" +
			LIB +
			" is missing; build it with build.sh (or build.bat on Windows)",
		)
	}
}

State :: distinct rawptr

// Lua's allocator interface. `ptr` is nil to allocate, nsize 0 to free.
Alloc_Proc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr

// Called every HOOK_COUNT instructions of a running script, and of every
// coroutine it makes. Returns HOOK_CONTINUE, HOOK_YIELD (suspend the script
// until it is resumed, if that can be done where it is) or HOOK_KILL.
Hook :: struct {
	check: #type proc "c" (ud: rawptr, thread: State) -> c.int,
	ud:    rawptr,
}

HOOK_COUNT :: 1000
HOOK_CONTINUE :: 0
HOOK_YIELD :: 1
HOOK_KILL :: 2

// What spawning and resuming return.
Lua_Status :: enum c.int {
	Ok      = 0, // spawned, or the task finished
	Error   = 1, // the message is in the buffer
	Missing = 2, // spawn_global: no such function
	Yield   = 3, // resume: suspended
}
