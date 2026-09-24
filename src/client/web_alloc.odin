#+build wasi
package client

import "base:runtime"
import "core:mem"

/*
Memory in a web build.

Emscripten's malloc owns the page's linear memory, growing it as it
needs to. Odin's own wasm allocator would grow the same memory behind
its back, and the two would end up handing out the same pages - so in a
web build every allocation goes through malloc instead, and the context
that says so is built once and handed to anything that runs outside the
frame loop (GLFW's callbacks; see callback_context).

Odin's temp allocator would draw on that same wasm allocator, so there
is an arena here for it too, on top of malloc, emptied at the top of
every frame like the desktop's.
*/

@(default_calling_convention = "c")
foreign _ {
	malloc :: proc(size: uint) -> rawptr ---
	calloc :: proc(count, size: uint) -> rawptr ---
	realloc :: proc(ptr: rawptr, size: uint) -> rawptr ---
	free :: proc(ptr: rawptr) ---
	aligned_alloc :: proc(alignment, size: uint) -> rawptr ---
}

// malloc hands out memory aligned for anything up to this.
@(private = "file")
MALLOC_ALIGNMENT :: 16

@(private = "file")
TEMP_ARENA_SIZE :: 4 * mem.Megabyte

@(private = "file")
g_temp_arena: runtime.Arena

@(private = "file")
g_web_context: runtime.Context

// web_context_init builds the context a web build runs in: malloc for
// the heap and an arena on top of it for temporaries.
web_context_init :: proc "contextless" () -> runtime.Context {
	context = runtime.default_context()
	context.allocator = malloc_allocator()
	_ = runtime.arena_init(&g_temp_arena, TEMP_ARENA_SIZE, context.allocator)
	context.temp_allocator = runtime.arena_allocator(&g_temp_arena)
	g_web_context = context
	return context
}

// web_context_set_logger records the logger once there is one, so that
// callbacks log like everything else.
web_context_set_logger :: proc "contextless" (logger: runtime.Logger) {
	g_web_context.logger = logger
}

// callback_context is the context for code the browser calls on its
// own - input callbacks - rather than through the frame loop.
callback_context :: proc "contextless" () -> runtime.Context {
	return g_web_context
}

malloc_allocator :: proc "contextless" () -> runtime.Allocator {
	return {procedure = malloc_allocator_proc}
}

@(private = "file")
malloc_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 {
			return nil, nil
		}
		p: rawptr
		if alignment <= MALLOC_ALIGNMENT {
			p = calloc(1, uint(size)) if mode == .Alloc else malloc(uint(size))
		} else {
			// aligned_alloc wants a size that's a multiple of the alignment.
			rounded := (size + alignment - 1) / alignment * alignment
			p = aligned_alloc(uint(alignment), uint(rounded))
			if p != nil && mode == .Alloc {
				mem.zero(p, size)
			}
		}
		if p == nil {
			return nil, .Out_Of_Memory
		}
		return ([^]byte)(p)[:size], nil

	case .Free:
		free(old_memory)
		return nil, nil

	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return malloc_allocator_proc(allocator_data, .Alloc, size, alignment, nil, 0, loc)
		}
		if alignment > MALLOC_ALIGNMENT {
			// realloc can't promise the alignment, so move it by hand.
			new_data, err := malloc_allocator_proc(allocator_data, .Alloc, size, alignment, nil, 0, loc)
			if err != nil {
				return nil, err
			}
			copy(new_data, ([^]byte)(old_memory)[:min(old_size, size)])
			free(old_memory)
			return new_data, nil
		}
		p := realloc(old_memory, uint(size))
		if p == nil && size > 0 {
			return nil, .Out_Of_Memory
		}
		if mode == .Resize && size > old_size {
			mem.zero(rawptr(uintptr(p) + uintptr(old_size)), size - old_size)
		}
		return ([^]byte)(p)[:size], nil

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
