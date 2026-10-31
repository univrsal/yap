#+build wasi
// The C declarations for a web build. They are the same as in
// lua_foreign.odin and are generated from it by tools/gen_foreign.py.
// On wasm, Odin names the procs of a named foreign import after the import
// ("system:c..name"), which no C object defines. The unnamed form,
// `foreign _`, keeps the plain C names that emscripten links against.
package script

import "core:c"

@(default_calling_convention = "c", link_prefix = "yap_lua_")
foreign _ {
	// A state with the libraries scripts may use; nil if out of memory. `hook`
	// must outlive it.
	state_new :: proc(alloc: Alloc_Proc, alloc_ud: rawptr, hook: ^Hook) -> State ---
	state_close :: proc(s: State) ---
	collect_garbage :: proc(s: State) ---
	// Make the global table yap with a function for each of `names` (see Hook.host);
	// the first has to be "_log". 0, or 1 if out of memory.
	register :: proc(s: State, names: [^]cstring, count: c.int) -> c.int ---
	// Make a coroutine to run with resume: the text of a script, or a call of
	// a global function with a value as its argument (nil: none). thread and
	// ref identify it; the ref is for release. On .Error the message is in err
	// and there is nothing to release.
	spawn_chunk :: proc(s: State, src: [^]u8, srclen: c.size_t, name: cstring, thread: ^State, ref: ^c.int, nargs: ^c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	spawn_global :: proc(s: State, name: cstring, arg: ^C_Value, thread: ^State, ref: ^c.int, nargs: ^c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	// A call of the Lua function that a C_FUNC argument referred to.
	spawn_ref :: proc(s: State, fn: c.int, arg: ^C_Value, thread: ^State, ref: ^c.int, nargs: ^c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	// Run a task until it finishes (.Ok), fails (.Error, with the message) or
	// is suspended (.Yield).
	resume :: proc(s: State, thread: State, nargs: c.int, err: [^]u8, errlen: c.size_t) -> Lua_Status ---
	release :: proc(s: State, ref: c.int) ---
}
