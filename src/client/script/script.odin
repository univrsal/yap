// A script: a Lua state of its own, and the handlers that run in it.
//
// Scripts must never stall the client, and the web build has no threads to
// run them on, so a handler is a coroutine that is run in small slices
// (scripts_step, once per frame): a hook that runs every HOOK_COUNT
// instructions looks at the clock and suspends the coroutine when its slice is
// used up; the next frame it goes on. A handler that is still running after
// `limits.total` of running time (an endless loop, say) is killed. Nothing
// here waits for anything. See docs/design/scripting.md.
package script

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"

Limits :: struct {
	// What the script's Lua state may hold, in bytes. Allocating past it fails
	// as it would with no memory left, which is an error in the script. 0: no
	// limit.
	memory: int,
	// How long one run of a handler may take, added up over all its slices. 0:
	// no limit.
	total:  time.Duration,
}

DEFAULT_LIMITS :: Limits {
	memory = 16 * 1024 * 1024,
	total  = 200 * time.Millisecond,
}

// The longest a task is run before the others get their turn.
TASK_SLICE :: 500 * time.Microsecond

// The longest message (and so error) we keep.
ERROR_LEN :: 512

Script :: struct {
	name:      string, // owned
	state:     State,
	limits:    Limits,
	// The tasks that haven't finished, in the order they get their turn.
	tasks:     [dynamic]Task,
	// What the hook needs to know, and the allocator. Their addresses are
	// handed to C, so a Script stays where create put it.
	hook:      Hook,
	mem:       Memory,
	run:       Run,
	allocator: runtime.Allocator,
}

@(private)
Memory :: struct {
	allocator: runtime.Allocator,
	used:      int,
	limit:     int,
}

// The task being run, for the hook.
@(private)
Run :: struct {
	thread:    State, // the coroutine being resumed; nil if none is
	began:     time.Tick, // when it was
	slice_end: time.Tick,
	spent:     time.Duration, // of its earlier slices
	killed:    bool,
}

// One run of a handler (or of the script's own code, when it is loaded).
Task :: struct {
	name:   string, // owned
	thread: State,
	ref:    c.int,
	nargs:  c.int, // for the first resume
	spent:  time.Duration, // running time so far
	slices: int,
}

Status :: enum {
	Finished,
	Error, // the script raised an error (or ran out of memory)
	Killed, // it ran for too long
}

Result :: struct {
	name:    string, // the handler, or the script's name for its own code; owned
	status:  Status,
	message: string, // the error; owned, "" if there is none
	spent:   time.Duration,
	slices:  int,
}

result_destroy :: proc(r: ^Result, allocator := context.allocator) {
	delete(r.name, allocator)
	delete(r.message, allocator)
	r^ = {}
}

results_clear :: proc(results: ^[dynamic]Result, allocator := context.allocator) {
	for &r in results {
		result_destroy(&r, allocator)
	}
	clear(results)
}

// create makes a script with nothing loaded. `name` is for messages. It is nil
// if there was no memory for a Lua state.
create :: proc(
	name: string,
	limits := DEFAULT_LIMITS,
	allocator := context.allocator,
) -> (
	s: ^Script,
) {
	s = new(Script, allocator)
	s.allocator = allocator
	s.name = strings.clone(name, allocator)
	s.limits = limits
	s.tasks.allocator = allocator
	s.mem = {
		allocator = allocator,
		limit     = limits.memory,
	}
	s.hook = {
		check = hook_check,
		ud    = s,
	}
	s.state = state_new(lua_alloc, &s.mem, &s.hook)
	if s.state == nil {
		delete(s.name, allocator)
		free(s, allocator)
		return nil
	}
	return s
}

// destroy ends the script and what it was still doing.
destroy :: proc(s: ^Script) {
	if s == nil {
		return
	}
	for &t in s.tasks {
		delete(t.name, s.allocator)
	}
	delete(s.tasks)
	state_close(s.state)
	allocator := s.allocator
	delete(s.name, allocator)
	free(s, allocator)
}

// memory_used is what the script's Lua state holds.
memory_used :: proc(s: ^Script) -> int {
	return s.mem.used
}

// collect frees everything the script no longer uses.
collect :: proc(s: ^Script) {
	collect_garbage(s.state)
}

// pending is how many tasks have not finished.
pending :: proc(s: ^Script) -> int {
	return len(s.tasks)
}

// run_source queues the text of a script to be run: its own code, which
// defines the handlers. The syntax is checked now. An error is the message.
run_source :: proc(s: ^Script, source: string) -> (err: string, ok: bool) {
	chunk_name := strings.concatenate({"=", s.name}, context.temp_allocator)
	cname, _ := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	buf: [ERROR_LEN]u8
	t := Task {
		name = s.name,
	}
	src := raw_data(source)
	status := spawn_chunk(s.state, src, c.size_t(len(source)), cname, &t.thread, &t.ref, &t.nargs, &buf[0], len(buf))
	return queue(s, &t, status, buf[:])
}

// call queues a call of the global function `handler`, with `arg` as its
// argument if there is one. A script that has no such function (it doesn't
// care about that event) is not an error: `ok` is false and `err` empty.
call :: proc(s: ^Script, handler: string, arg: Maybe(string) = nil) -> (err: string, ok: bool) {
	cname, _ := strings.clone_to_cstring(handler, context.temp_allocator)
	buf: [ERROR_LEN]u8
	t := Task {
		name = handler,
	}
	a: [^]u8
	n: c.size_t
	if text, has := arg.?; has {
		a = raw_data(text)
		n = c.size_t(len(text))
		if a == nil {
			a = raw_data(buf[:]) // an empty string still is an argument
		}
	}
	status := spawn_global(s.state, cname, a, n, &t.thread, &t.ref, &t.nargs, &buf[0], len(buf))
	return queue(s, &t, status, buf[:])
}

@(private)
queue :: proc(s: ^Script, t: ^Task, status: Lua_Status, buf: []u8) -> (err: string, ok: bool) {
	#partial switch status {
	case .Ok:
		t.name = strings.clone(t.name, s.allocator)
		append(&s.tasks, t^)
		return "", true
	case .Missing:
		return "", false
	}
	return message_of(buf), false
}

// The text in a C buffer, in the temporary allocator.
@(private)
message_of :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// step runs the script's tasks for about `budget`: each gets a turn of up to
// TASK_SLICE in turn, until they have all finished or the time is up. What
// finished is added to `results`, which the caller clears (results_clear).
step :: proc(s: ^Script, budget: time.Duration, results: ^[dynamic]Result) {
	frame_end := time.tick_add(time.tick_now(), budget)
	for len(s.tasks) > 0 {
		for i := 0; i < len(s.tasks); {
			now := time.tick_now()
			if time.tick_diff(frame_end, now) >= 0 {
				return
			}
			slice_end := time.tick_add(now, TASK_SLICE)
			if time.tick_diff(slice_end, frame_end) < 0 {
				slice_end = frame_end
			}
			if resume_task(s, &s.tasks[i], now, slice_end, results) {
				ordered_remove(&s.tasks, i)
			} else {
				i += 1
			}
		}
	}
}

// resume_task runs a task until `slice_end`. It is true if it is over.
@(private)
resume_task :: proc(
	s: ^Script,
	t: ^Task,
	now, slice_end: time.Tick,
	results: ^[dynamic]Result,
) -> (
	over: bool,
) {
	s.run = {
		thread    = t.thread,
		began     = now,
		slice_end = slice_end,
		spent     = t.spent,
	}
	buf: [ERROR_LEN]u8
	nargs := t.nargs
	t.nargs = 0
	status := resume(s.state, t.thread, nargs, &buf[0], len(buf))
	t.spent += time.tick_since(now)
	t.slices += 1
	killed := s.run.killed
	s.run = {}

	if status == .Yield && !killed {
		return false
	}
	r := Result {
		name   = t.name,
		status = .Finished,
		spent  = t.spent,
		slices = t.slices,
	}
	if killed {
		r.status = .Killed
		r.message = strings.clone("ran for too long", s.allocator)
	} else if status == .Error {
		r.status = .Error
		r.message = strings.clone(string(cstring(&buf[0])), s.allocator)
	}
	append(results, r) // the result owns the name now
	release(s.state, t.ref)
	return true
}

@(private)
hook_check :: proc "c" (ud: rawptr, thread: State) -> c.int {
	context = runtime.default_context()
	s := (^Script)(ud)
	r := &s.run
	if r.thread == nil {
		return HOOK_CONTINUE // not a task: nothing limits it, nothing can wait
	}
	now := time.tick_now()
	if r.killed {
		return HOOK_KILL
	}
	if s.limits.total > 0 && r.spent + time.tick_diff(r.began, now) > s.limits.total {
		r.killed = true
		return HOOK_KILL
	}
	// Only the task itself can be suspended. A coroutine it made yields to the
	// script, not to us, so that one runs until the limit above.
	if thread == r.thread && time.tick_diff(r.slice_end, now) >= 0 {
		return HOOK_YIELD
	}
	return HOOK_CONTINUE
}

// Lua's allocator. Growing past the limit fails, as with no memory left;
// shrinking never does.
@(private)
lua_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	m := (^Memory)(ud)
	context = runtime.default_context()
	context.allocator = m.allocator
	old := int(osize) if ptr != nil else 0
	if nsize == 0 {
		if ptr != nil {
			runtime.mem_free_with_size(ptr, old)
			m.used -= old
		}
		return nil
	}
	size := int(nsize)
	if m.limit > 0 && size > old && m.used - old + size > m.limit {
		return nil
	}
	data, err := runtime.mem_resize(ptr, old, size)
	if err != nil {
		return nil
	}
	m.used += size - old
	return raw_data(data)
}
