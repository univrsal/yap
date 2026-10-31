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

// A value passing between a script and the host (yap_value in yap_lua.h). For
// a map, `items` has a key (a STR, NUL terminated) and its value for each of
// `count` entries.
C_Value :: struct {
	type:  c.int,
	i:     c.longlong,
	n:     f64,
	s:     [^]u8,
	len:   c.size_t,
	items: [^]C_Value,
	count: c.size_t,
}

C_NIL :: 0
C_BOOL :: 1
C_INT :: 2
C_NUM :: 3
C_STR :: 4
C_LIST :: 5
C_MAP :: 6
// Only in what a host function is given: a reference to a Lua function that the
// host may keep (and then must release), see Hook.host.
C_FUNC :: 7

// What the hook of the script's state calls into: `check` every HOOK_COUNT
// instructions of a running script (and of every coroutine it makes), which
// returns HOOK_CONTINUE, HOOK_YIELD (suspend the script until it is resumed,
// if that can be done where it is) or HOOK_KILL; and `host` when the script
// calls one of the yap.* functions (see register): op is the position of the
// function in the names given there. It returns 0 with the value to return in
// `ret`, or 1 with an error message (a C_STR) in it. What `ret` points to has
// to stay valid until the next call. A C_FUNC among the arguments is released
// after the call, unless the host keeps it by setting its type to C_NIL.
Hook :: struct {
	check: #type proc "c" (ud: rawptr, thread: State) -> c.int,
	host:  #type proc "c" (ud: rawptr, op: c.int, args: [^]C_Value, nargs: c.int, ret: ^C_Value) -> c.int,
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
