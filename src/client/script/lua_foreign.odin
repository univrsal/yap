#+build !wasi
package script

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib {LIB}
} else {
	foreign import lib {LIB, "system:m"}
}

@(default_calling_convention = "c", link_prefix = "yap_lua_")
foreign lib {
	// A state with the libraries scripts may use; nil if out of memory. `hook`
	// must outlive it.
	state_new :: proc(alloc: Alloc_Proc, alloc_ud: rawptr, hook: ^Hook) -> State ---
	state_close :: proc(s: State) ---
	collect_garbage :: proc(s: State) ---
	// Make a coroutine to run with resume: the text of a script, or a call of
	// a global function with a string as its argument (nil: none). thread and
	// ref identify it; the ref is for release. On .Error the message is in err
	// and there is nothing to release.
	spawn_chunk :: proc(s: State, src: [^]u8, srclen: c.size_t, name: cstring, thread: ^State, ref: ^c.int, nargs: ^c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	spawn_global :: proc(s: State, name: cstring, arg: [^]u8, arglen: c.size_t, thread: ^State, ref: ^c.int, nargs: ^c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	// Run a task until it finishes (.Ok), fails (.Error, with the message) or
	// is suspended (.Yield).
	resume :: proc(s: State, thread: State, nargs: c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	release :: proc(s: State, ref: c.int) ---
}
