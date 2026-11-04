// A script: a Lua state of its own, and the handlers that run in it.
//
// Scripts must never stall the client, and the web build has no threads to
// run them on, so a handler is a coroutine that is run in small slices
// (scripts_step, once per frame): a hook that runs every HOOK_COUNT
// instructions looks at the clock and suspends the coroutine when its slice is
// used up; the next frame it goes on. A handler that is still running after
// `limits.total` of running time (an endless loop, say) is killed. Nothing
// here waits for anything. See docs/design/scripting.md.
//
// What a script can do to the outside is the yap.* functions (api.odin), which
// ask the Host (the runtime, runtime.odin) to do it.
package script

import "base:runtime"
import "core:c"
import "core:fmt"
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

// Which of the things that reach out of the script it may do (api.odin).
Permission :: enum {
	Send, // post messages as the user
	Notify, // show desktop notifications (yap.notify) and status text (yap.status)
	Net, // make web requests (yap.http_get, yap.http_post)
}

Permissions :: bit_set[Permission]

// Which server an event, and what a script does about it, is about. 0 is none
// (the script's own code runs on no server's behalf).
Server_Id :: distinct u64

// What a script's yap.* functions do, apart from those that only concern the
// script (timers and its store). Each returns an error message, "" if it went
// well. The runtime provides them; a test provides its own.
Host :: struct {
	data:           rawptr,
	log:            proc(host: ^Host, s: ^Script, text: string),
	send:           proc(
		host: ^Host,
		s: ^Script,
		server: Server_Id,
		channel, text: string,
	) -> string,
	// A desktop notification, like the client's own for mentions and calls.
	notify:         proc(
		host: ^Host,
		s: ^Script,
		server: Server_Id,
		title, text: string,
	) -> string,
	// A line of text in the client's status area (the top of the chat window).
	status:         proc(host: ^Host, s: ^Script, server: Server_Id, text: string) -> string,
	// The server with this key, 0 if the script has no such server (it isn't
	// one it runs for, or there is none).
	server_by_key:  proc(host: ^Host, s: ^Script, key: string) -> Server_Id,
	// Web requests (http.odin). `http_begin` starts one, an error message if it
	// can't, and the host reports the outcome with http_finish; `http_cancel` is for
	// when the script is going, with requests still out.
	http_available: proc(host: ^Host) -> bool,
	http_begin:     proc(host: ^Host, s: ^Script, id: u64, req: Http_Request) -> string,
	http_cancel:    proc(host: ^Host, s: ^Script),
}

// A /command the script registered with yap.register_command: what the user
// types, a line of help, and the function that runs.
Command :: struct {
	name: string, // owned; lower case
	help: string, // owned
	fn:   c.int, // a reference to it in the script's Lua state
}

// A name that fires `on_timer` after a while.
@(private)
Timer :: struct {
	name:     string, // owned
	due:      time.Tick,
	interval: time.Duration, // 0 for once
	server:   Server_Id,
}

Script :: struct {
	name:           string, // owned
	state:          State,
	limits:         Limits,
	perms:          Permissions,
	host:           ^Host,
	// The values of its settings (info.odin), for yap.setting: the user's choices,
	// the defaults where there are none. Scalars; the strings are owned.
	settings:       map[string]Value,
	// Being read for its get_info only: every yap.* function does nothing, so that
	// what it does when it loads (registering commands, say) is harmless.
	meta:           bool,
	// Being destroyed: closing the Lua state runs the script's finalizers, which
	// must not reach the host state that destroy is freeing. Every yap.*
	// function does nothing from then on.
	closing:        bool,
	timers:         [dynamic]Timer,
	// The /commands it registered (api.odin).
	commands:       [dynamic]Command,
	// Web requests that are out, answers waiting to be given (http.odin), and the
	// requests started in the current minute.
	requests:       [dynamic]Pending_Request,
	completions:    [dynamic]Completion,
	next_request:   u64,
	http_window:    time.Tick,
	http_count:     int,
	// The argument of the host call being made that the host keeps (a function),
	// -1 for none.
	keep_arg:       int,
	// What the script keeps between runs: yap.store (api.odin). Only scalars.
	store:          map[string]Value,
	store_size:     int, // the bytes in it, as far as they are counted
	store_dirty:    bool, // it changed since the runtime last saved it
	// Filters (filter below) that went wrong in a row; at MAX_FILTER_STRIKES they
	// are switched off for this script.
	filter_strikes: int,
	filters_off:    bool,
	// How many messages it has sent in the current SEND_WINDOW, and notifications
	// in the current NOTIFY_WINDOW (api.odin).
	send_window:    time.Tick,
	sent:           int,
	notify_window:  time.Tick,
	notified:       int,
	// Memory for the values passed to a host function and back; emptied at the
	// start of every call of one.
	scratch:        runtime.Arena,
	// The tasks that haven't finished, in the order they get their turn.
	tasks:          [dynamic]Task,
	// What the hook needs to know, and the allocator. Their addresses are
	// handed to C, so a Script stays where create put it.
	hook:           Hook,
	mem:            Memory,
	run:            Run,
	allocator:      runtime.Allocator,
	// The context it was made in: what the callbacks from C run in, so they log
	// like everything else.
	ctx:            runtime.Context,
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
	server:    Server_Id, // on whose behalf
	began:     time.Tick, // when it was
	slice_end: time.Tick,
	spent:     time.Duration, // of its earlier slices
	killed:    bool,
	// A filter (see filter) is run to the end, never suspended, and for no
	// longer than `limit`.
	sync:      bool,
	limit:     time.Duration,
}

// One run of a handler (or of the script's own code, when it is loaded).
Task :: struct {
	name:   string, // owned
	thread: State,
	ref:    c.int,
	nargs:  c.int, // for the first resume
	server: Server_Id,
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
	s.ctx = context
	s.name = strings.clone(name, allocator)
	s.limits = limits
	s.tasks.allocator = allocator
	s.mem = {
		allocator = allocator,
		limit     = limits.memory,
	}
	s.hook = {
		check = hook_check,
		host  = host_call,
		ud    = s,
	}
	s.timers.allocator = allocator
	s.commands.allocator = allocator
	s.requests.allocator = allocator
	s.completions.allocator = allocator
	s.keep_arg = -1
	s.store.allocator = allocator
	s.settings.allocator = allocator
	if runtime.arena_init(&s.scratch, 64 * 1024, allocator) != nil {
		delete(s.name, allocator)
		free(s, allocator)
		return nil
	}
	s.state = state_new(lua_alloc, &s.mem, &s.hook)
	if s.state == nil || !register_api(s) {
		if s.state != nil {
			state_close(s.state)
		}
		runtime.arena_destroy(&s.scratch)
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
	// First: closing the state runs whatever finalizers the script managed to
	// set up (the bootstrap refuses __gc, this is the second line), and they
	// must find nothing of the host state left to touch.
	s.closing = true
	state_close(s.state)
	for &t in s.tasks {
		delete(t.name, s.allocator)
	}
	delete(s.tasks)
	for &t in s.timers {
		delete(t.name, s.allocator)
	}
	delete(s.timers)
	for c in s.commands {
		delete(c.name, s.allocator)
		delete(c.help, s.allocator)
	}
	delete(s.commands)
	delete(s.requests)
	for &c in s.completions {
		response_destroy(&c.response, s.allocator)
	}
	delete(s.completions)
	store_clear(s)
	delete(s.store)
	settings_clear(s)
	delete(s.settings)
	runtime.arena_destroy(&s.scratch)
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
	status := spawn_chunk(
		s.state,
		src,
		c.size_t(len(source)),
		cname,
		&t.thread,
		&t.ref,
		&t.nargs,
		&buf[0],
		len(buf),
	)
	return queue(s, &t, status, buf[:])
}

// call queues a call of the global function `handler`, with `arg` as its
// argument if it isn't nil, on behalf of `server`. A script that has no such
// function (it doesn't care about that event) is not an error: `ok` is false
// and `err` empty.
call :: proc(
	s: ^Script,
	handler: string,
	arg: Value = nil,
	server := Server_Id(0),
) -> (
	err: string,
	ok: bool,
) {
	cname, _ := strings.clone_to_cstring(handler, context.temp_allocator)
	buf: [ERROR_LEN]u8
	t := Task {
		name   = handler,
		server = server,
	}
	free_all(runtime.arena_allocator(&s.scratch))
	defer free_all(runtime.arena_allocator(&s.scratch))
	value: C_Value
	has_arg := arg != nil
	if has_arg {
		value = to_c(arg, runtime.arena_allocator(&s.scratch))
	}
	status := spawn_global(
		s.state,
		cname,
		&value if has_arg else nil,
		&t.thread,
		&t.ref,
		&t.nargs,
		&buf[0],
		len(buf),
	)
	return queue(s, &t, status, buf[:])
}

// call_command queues a run of the /command `name` (without the slash) with
// `arg`, on behalf of `server`. `ok` is false if the script has no such command.
call_command :: proc(
	s: ^Script,
	name: string,
	arg: Value,
	server := Server_Id(0),
) -> (
	err: string,
	ok: bool,
) {
	fn := c.int(-1)
	for cmd in s.commands {
		if cmd.name == name {
			fn = cmd.fn
		}
	}
	if fn < 0 {
		return "", false
	}
	buf: [ERROR_LEN]u8
	t := Task {
		name   = strings.concatenate({"/", name}, context.temp_allocator),
		server = server,
	}
	free_all(runtime.arena_allocator(&s.scratch))
	defer free_all(runtime.arena_allocator(&s.scratch))
	value := to_c(arg, runtime.arena_allocator(&s.scratch))
	status := spawn_ref(s.state, fn, &value, &t.thread, &t.ref, &t.nargs, &buf[0], len(buf))
	return queue(s, &t, status, buf[:])
}

// How long a filter may run, and how many go wrong in a row before the
// script's filters are switched off.
FILTER_LIMIT :: 2 * time.Millisecond
MAX_FILTER_STRIKES :: 3

Filter_Outcome :: enum {
	Unchanged, // nothing returned (or true), or the script has no such function
	Hide, // false
	Replace, // a string
}

// call_sync calls the global function `handler` with `arg` and waits for what
// it returns: its first result as a Value (nil, a boolean, a number, a string, or
// a table of those as a List or a Map), copied into `allocator`. It runs to the end
// now and can't be suspended, so it is killed after `limit`. `found` is false if
// there is no such function, and `err` says what went wrong if it did.
call_sync :: proc(
	s: ^Script,
	handler: string,
	arg: Value,
	server := Server_Id(0),
	limit := FILTER_LIMIT,
	allocator := context.temp_allocator,
) -> (
	result: Value,
	found: bool,
	err: string,
) {
	cname, _ := strings.clone_to_cstring(handler, context.temp_allocator)
	buf: [ERROR_LEN]u8
	thread: State
	ref, nargs: c.int
	arena := runtime.arena_allocator(&s.scratch)
	free_all(arena)
	defer free_all(arena)
	value := to_c(arg, arena)
	#partial switch spawn_global(
		s.state,
		cname,
		&value,
		&thread,
		&ref,
		&nargs,
		&buf[0],
		len(buf),
	) {
	case .Missing:
		return nil, false, ""
	case .Error:
		return nil, true, message_of(buf[:])
	}
	defer release(s.state, ref)

	saved := s.run
	s.run = Run {
		thread = thread,
		server = server,
		began  = time.tick_now(),
		sync   = true,
		limit  = limit,
	}
	raw: C_Value
	status := resume(s.state, thread, nargs, &buf[0], len(buf), &raw)
	killed := s.run.killed
	s.run = saved
	switch {
	case killed:
		return nil, true, "ran for too long"
	case status == .Error:
		return nil, true, message_of(buf[:])
	case status == .Yield:
		return nil, true, "it cannot wait (it yielded)"
	}
	result = from_c(raw, allocator)
	value_free(&raw)
	return result, true, ""
}

// filter is call_sync for a handler that answers a question about a message:
// nothing or true leaves things as they are, false hides, a string replaces.
// Unlike call it runs to the end now, and is killed after FILTER_LIMIT. A filter
// that fails or runs too long counts as a strike, and after MAX_FILTER_STRIKES in
// a row the script's filters are off (a good one clears them). `err` says what
// went wrong. The replacement is in `allocator`.
filter :: proc(
	s: ^Script,
	handler: string,
	arg: Value,
	server := Server_Id(0),
	allocator := context.temp_allocator,
) -> (
	outcome: Filter_Outcome,
	text: string,
	err: string,
) {
	if s.filters_off {
		return
	}
	result, found, why := call_sync(s, handler, arg, server, FILTER_LIMIT, allocator)
	if !found {
		return
	}
	if why != "" {
		return .Unchanged, "", strike(s, handler, why)
	}
	s.filter_strikes = 0
	switch x in result {
	case bool:
		if !x {
			outcome = .Hide
		}
	case string:
		outcome, text = .Replace, x
	case i64, f64, List, Map, Function:
	}
	return
}

@(private = "file")
strike :: proc(s: ^Script, handler, why: string) -> string {
	s.filter_strikes += 1
	if s.filter_strikes >= MAX_FILTER_STRIKES {
		s.filters_off = true
		return fmt.tprintf("%s: %s (filters switched off)", handler, why)
	}
	return fmt.tprintf("%s: %s", handler, why)
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
	fire_timers(s)
	completions_deliver(s)
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
		server    = t.server,
		began     = now,
		slice_end = slice_end,
		spent     = t.spent,
	}
	buf: [ERROR_LEN]u8
	nargs := t.nargs
	t.nargs = 0
	status := resume(s.state, t.thread, nargs, &buf[0], len(buf), nil)
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
	limit := r.limit if r.limit > 0 else s.limits.total
	if limit > 0 && r.spent + time.tick_diff(r.began, now) > limit {
		r.killed = true
		return HOOK_KILL
	}
	// Only the task itself can be suspended. A coroutine it made yields to the
	// script, not to us, so that one runs until the limit above.
	if !r.sync && thread == r.thread && time.tick_diff(r.slice_end, now) >= 0 {
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
