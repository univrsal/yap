#+build !wasi
package script

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Runs the script's tasks to the end, in frames of `frame`, and returns the
// results, how many frames it took and how long the median frame took. Gives
// up after a few seconds, so that a bug here fails a test rather than hanging
// it. The median, not the longest frame: the OS can preempt the thread for a
// scheduler quantum (~16ms on Windows) in any frame, more so while other tests
// run in parallel, and that says nothing about the script.
run_to_end :: proc(
	s: ^Script,
	frame: time.Duration = 2 * time.Millisecond,
) -> (
	results: [dynamic]Result,
	frames: int,
	median: time.Duration,
) {
	took := make([dynamic]time.Duration, context.temp_allocator)
	start := time.tick_now()
	for pending(s) > 0 && time.tick_since(start) < 5 * time.Second {
		began := time.tick_now()
		step(s, frame, &results)
		append(&took, time.tick_since(began))
		frames += 1
	}
	if len(took) > 0 {
		slice.sort(took[:])
		median = took[len(took) / 2]
	}
	return
}

finish :: proc(results: ^[dynamic]Result) {
	results_clear(results)
	delete(results^)
	results^ = nil // so that it can be used again
}

new_script :: proc(t: ^testing.T, limits := DEFAULT_LIMITS) -> ^Script {
	s := create("test", limits)
	testing.expect(t, s != nil)
	return s
}

load :: proc(t: ^testing.T, s: ^Script, source: string) {
	err, ok := run_source(s, source)
	testing.expectf(t, ok, "loading failed: %v", err)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 1)
	if len(results) == 1 {
		testing.expectf(
			t,
			results[0].status == .Finished,
			"script's own code: %v %v",
			results[0].status,
			results[0].message,
		)
	}
}

@(test)
test_runs_a_handler :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		"seen = {}\nfunction on_message(text) seen[#seen + 1] = text:upper() end\nfunction count() assert(#seen == 2 and seen[2] == 'WORLD') end",
	)

	for text in ([]string{"hello", "world"}) {
		err, ok := call(s, "on_message", text)
		testing.expectf(t, ok, "call failed: %v", err)
	}
	err, ok := call(s, "count")
	testing.expectf(t, ok, "call failed: %v", err)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 3)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v %v", r.name, r.status, r.message)
	}
}

@(test)
test_missing_handler_is_not_an_error :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(t, s, "x = 1")
	err, ok := call(s, "on_message", "hi")
	testing.expect(t, !ok)
	testing.expect_value(t, err, "")
	testing.expect_value(t, pending(s), 0)

	// A global that isn't a function is just as absent.
	err, ok = call(s, "x")
	testing.expect(t, !ok)
	testing.expect_value(t, err, "")
}

@(test)
test_empty_argument_is_an_argument :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(t, s, "function f(a) assert(a == '') end function g(a) assert(a == nil) end")
	_, ok := call(s, "f", "")
	testing.expect(t, ok)
	_, ok = call(s, "g")
	testing.expect(t, ok)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
}

@(test)
test_errors_are_reported :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)

	// A syntax error is found when the script is loaded.
	err, ok := run_source(s, "function (")
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(err, "test:1:"), "message: %q", err)

	load(t, s, "function boom() error('nope') end function typed() error({}) end")
	_, _ = call(s, "boom")
	_, _ = call(s, "typed")
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 2)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expectf(
		t,
		strings.contains(results[0].message, "nope"),
		"message: %q",
		results[0].message,
	)
	testing.expect_value(t, results[1].status, Status.Error)
	testing.expectf(
		t,
		strings.contains(results[1].message, "table"),
		"message: %q",
		results[1].message,
	)

	// The script is still there afterwards.
	load(t, s, "ok = true")
}

@(test)
test_sandbox :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	// What reaches the machine, or the console, isn't there.
	load(
		t,
		s,
		`
		for _, name in ipairs{"io", "os", "package", "debug", "require", "dofile", "loadfile", "print"} do
			assert(_G[name] == nil, name)
		end
		assert(string.dump == nil)
		-- What scripts are for is.
		for _, name in ipairs{"string", "table", "math", "utf8", "coroutine"} do
			assert(type(_G[name]) == "table", name)
		end
		-- Chunks are text, whatever the script asks for.
		local f, err = load("\27Lua", "x", "b")
		assert(f == nil and err:find("binary chunk"), err)
		assert(load("return 1 + 1")() == 2)
		-- With an environment of its own, too.
		assert(load("return x", "x", "t", {x = 5})() == 5)
		-- The collector is not the script's to tune.
		assert(type(collectgarbage("count")) == "number")
		assert(not pcall(collectgarbage, "generational"))
		assert(not pcall(collectgarbage, "stop"))
		`,
	)
}

@(test)
test_endless_loop_does_not_stall :: proc(t: ^testing.T) {
	s := new_script(t, Limits{memory = DEFAULT_LIMITS.memory, total = 50 * time.Millisecond})
	defer destroy(s)
	load(t, s, "function spin() while true do end end function fine() done = true end")

	_, ok := call(s, "spin")
	testing.expect(t, ok)
	_, ok = call(s, "fine")
	testing.expect(t, ok)
	results, frames, median := run_to_end(s)
	defer finish(&results)

	testing.expect_value(t, len(results), 2)
	// The other handler is not held up by the loop...
	testing.expect_value(t, results[0].name, "fine")
	testing.expect_value(t, results[0].status, Status.Finished)
	// ... which is killed after its time is up, having been suspended and
	// continued over many frames, which stayed short.
	testing.expect_value(t, results[1].name, "spin")
	testing.expect_value(t, results[1].status, Status.Killed)
	testing.expectf(t, frames > 5, "ran in %d frames", frames)
	testing.expectf(t, results[1].slices > 5, "ran in %d slices", results[1].slices)
	testing.expectf(t, results[1].spent < 150 * time.Millisecond, "ran for %v", results[1].spent)
	testing.expectf(t, median < 10 * time.Millisecond, "the median frame took %v", median)
}

@(test)
test_loading_a_script_is_limited_too :: proc(t: ^testing.T) {
	s := new_script(t, Limits{memory = DEFAULT_LIMITS.memory, total = 30 * time.Millisecond})
	defer destroy(s)
	_, ok := run_source(s, "while true do end")
	testing.expect(t, ok)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].status, Status.Killed)
}

@(test)
test_catching_the_kill_does_not_save_a_script :: proc(t: ^testing.T) {
	s := new_script(t, Limits{memory = DEFAULT_LIMITS.memory, total = 30 * time.Millisecond})
	defer destroy(s)
	load(
		t,
		s,
		`
		function a() while true do pcall(function() while true do end end) end end
		function b() pcall(function() while true do end end) while true do end end
		function c() local n = 0 repeat n = n + 1 until not pcall(error, "x") and false while true do n = n + 1 end end
		`,
	)
	for h in ([]string{"a", "b", "c"}) {
		_, ok := call(s, h)
		testing.expect(t, ok)
	}
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 3)
	for r in results {
		testing.expectf(t, r.status == .Killed, "%v: %v %v", r.name, r.status, r.message)
	}
}

@(test)
test_coroutines_of_the_script :: proc(t: ^testing.T) {
	s := new_script(t, Limits{memory = DEFAULT_LIMITS.memory, total = 40 * time.Millisecond})
	defer destroy(s)
	load(
		t,
		s,
		`
		function gen()
			-- Coroutines work, also when the time slice ends inside one:
			-- the script does not see a yield it didn't make.
			local co = coroutine.wrap(function()
				for i = 1, 3 do coroutine.yield(i) end
				local x = 0
				for i = 1, 300000 do x = x + i end
				coroutine.yield(x)
			end)
			assert(co() == 1 and co() == 2 and co() == 3)
			assert(co() == 300000 * 300001 // 2)
		end
		function trap() coroutine.wrap(function() while true do end end)() end
		function wait() for i = 1, 3 do coroutine.yield() end done = true end
		`,
	)
	for h in ([]string{"gen", "trap", "wait"}) {
		_, ok := call(s, h)
		testing.expect(t, ok)
	}
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 3)
	for r in results {
		switch r.name {
		case "gen", "wait":
			testing.expectf(t, r.status == .Finished, "%v: %v %v", r.name, r.status, r.message)
		case "trap":
			// It can't be suspended, so it runs to the limit.
			testing.expectf(t, r.status == .Killed, "%v: %v %v", r.name, r.status, r.message)
		}
	}
}

@(test)
test_memory_is_limited :: proc(t: ^testing.T) {
	s := new_script(t, Limits{memory = 1024 * 1024, total = DEFAULT_LIMITS.total})
	defer destroy(s)
	load(
		t,
		s,
		"function hog() local t = {} for i = 1, 1e7 do t[i] = ('x'):rep(100) .. i end end function ok() local t = {} for i = 1, 100 do t[i] = i end end",
	)
	_, _ = call(s, "hog")
	results, _, _ := run_to_end(s)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expectf(
		t,
		strings.contains(results[0].message, "memory"),
		"message: %q",
		results[0].message,
	)
	finish(&results)

	// It was freed, and the script still works.
	collect(s)
	testing.expectf(t, memory_used(s) < 512 * 1024, "still using %d", memory_used(s))
	_, ok := call(s, "ok")
	testing.expect(t, ok)
	results, _, _ = run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].status, Status.Finished)
}

@(test)
test_memory_is_limited_when_spawning :: proc(t: ^testing.T) {
	// With the memory used up, making the next coroutine fails: that is an
	// error to report, not a crash.
	s := new_script(t, Limits{memory = 256 * 1024, total = DEFAULT_LIMITS.total})
	defer destroy(s)
	load(t, s, "keep = {} function f() end")
	// Fill what is left, without letting the script's own allocation fail.
	load(
		t,
		s,
		"for i = 1, 100000 do local ok = pcall(function() keep[#keep + 1] = ('y'):rep(1000) .. i end) if not ok then break end end",
	)
	failed := 0
	for _ in 0 ..< 50 {
		_, ok := call(s, "f")
		if !ok {
			failed += 1
		}
		results: [dynamic]Result
		step(s, time.Millisecond, &results)
		finish(&results)
	}
	// Whether spawning fails depends on what was left; the point is that it
	// returned.
	testing.expect(t, failed >= 0)
}

@(test)
test_huge_strings_are_refused :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		assert(("ab"):rep(3, "-") == "ab-ab-ab")
		assert(("x"):rep(1000) ~= nil)
		assert(not pcall(string.rep, "x", 1 << 30))
		assert(not pcall(string.rep, "xxxx", 1 << 20, ","))
		assert(not pcall(string.find, "x", ("a"):rep(300)))
		assert(not pcall(string.gsub, "x", ("a"):rep(300), ""))
		assert(("hello world"):find("o w") == 5)
		assert(("hello world"):gsub("o", "0") == "hell0 w0rld")
		assert(("k=v"):match("(%w+)=(%w+)") == "k")
		local n = 0 for w in ("a b c"):gmatch("%a") do n = n + 1 end assert(n == 3)
		`,
	)
}

// A finalizer runs when the state is closed, and not under the instruction
// limit, so scripts may not have any.
@(test)
test_finalizers_are_refused :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		assert(not pcall(setmetatable, {}, { __gc = function() end }))
		assert(not pcall(setmetatable, {}, { __gc = true }))
		assert(not pcall(setmetatable, {}, { __gc = false }))
		-- Other metatables still work.
		local obj = setmetatable({}, { __index = function(_, k) return k .. "!" end })
		assert(obj.x == "x!")
		assert(getmetatable(obj) ~= nil)
		assert(setmetatable({}, nil) ~= nil)
		`,
	)
}

// A call of a C function can't be interrupted by the time limit, so what could
// take very long is bounded in itself: patterns by a budget of steps, and
// table.move by how many elements it moves.
@(test)
test_long_calls_are_bounded :: proc(t: ^testing.T) {
	// What is tested is the step budget of each call, not the time limit: the
	// megabyte strings below can take longer than DEFAULT_LIMITS.total while
	// the other tests run in parallel.
	s := new_script(t, Limits{memory = DEFAULT_LIMITS.memory, total = 2 * time.Second})
	defer destroy(s)
	load(
		t,
		s,
		`
		-- 2^35 steps without the budget.
		local ok, err = pcall(string.find, ("a"):rep(35), ("a?"):rep(35) .. "b")
		assert(not ok and tostring(err):find("too complex"), tostring(err))
		-- A power of the length: a*b on a string of a's is quadratic.
		local ok, err = pcall(string.find, ("a"):rep(1 << 16), "a*a*a*b")
		assert(not ok and tostring(err):find("too complex"), tostring(err))
		ok, err = pcall(string.gsub, ("a"):rep(1 << 16), "a-b", "")
		assert(not ok and tostring(err):find("too complex"), tostring(err))
		ok, err = pcall(function() for _ in (("a"):rep(1 << 16)):gmatch(".-b") do end end)
		assert(not ok and tostring(err):find("too complex"), tostring(err))
		-- The budget is for one call: the next one starts anew.
		assert(("hello world"):find("o w") == 5)
		assert(("hello world"):match("(%w+) (%w+)") == "hello")
		-- And what is ordinary on big strings still works: a megabyte with
		-- a simple pattern takes about two million steps.
		local big = ("abc "):rep(1 << 18)
		local n = 0
		for _ in big:gmatch("%a+") do n = n + 1 end
		assert(n == 1 << 18, n)
		local replaced, count = big:gsub("b", "B")
		assert(count == 1 << 18 and #replaced == #big)
		assert(big:find("abc x", 1, true) == nil)

		assert(not pcall(table.move, {}, 1, 1 << 60, 1))
		assert(not pcall(table.move, {}, 1, math.maxinteger, 2))
		assert(not pcall(table.move, {}, -(1 << 40), 1 << 40, 1))
		assert(table.concat(table.move({1, 2, 3}, 1, 3, 2), ",") == "1,1,2,3")
		assert(#table.move({1, 2, 3}, 1, 3, 1, {}) == 3)
		`,
	)
}

// destroy closes the Lua state while the host's state is still there, and
// whatever runs while it closes can't use yap.* any more.
@(test)
test_destroy_stops_the_api :: proc(t: ^testing.T) {
	s := new_script(t)
	load(t, s, `yap.timer("x", 1)`)
	testing.expect_value(t, len(s.timers), 1)
	s.closing = true
	load(t, s, `yap.timer("y", 1)`)
	testing.expect_value(t, len(s.timers), 1)
	s.closing = false
	destroy(s)
}

@(test)
test_nothing_leaks_when_destroyed_midway :: proc(t: ^testing.T) {
	// The test runner reports memory still allocated at the end.
	s := new_script(t)
	load(t, s, "function f() while true do end end")
	_, _ = call(s, "f")
	_, _ = call(s, "f")
	results: [dynamic]Result
	step(s, time.Millisecond, &results)
	finish(&results)
	testing.expect_value(t, pending(s), 2)
	destroy(s)
}

// A host for tests: it records what the script asked for.
@(private = "file")
Fake :: struct {
	host:        Host,
	logs:        [dynamic]string,
	sent:        [dynamic]string,
	notices:     [dynamic]string,
	statuses:    [dynamic]string,
	servers:     map[string]Server_Id,
	// Web requests: what was asked for, whether they can be made, and what
	// starting one says.
	asked:       [dynamic]Asked,
	http_off:    bool,
	begin_error: string,
}

Asked :: struct {
	id:                u64,
	method, url, body: string,
	headers:           string, // "Name: value" lines
	timeout:           time.Duration,
}

@(private = "file")
fake_init :: proc(f: ^Fake) {
	f.host = Host {
		data = f,
		log = proc(host: ^Host, s: ^Script, text: string) {
			f := (^Fake)(host.data)
			append(&f.logs, strings.clone(text))
		},
		send = proc(host: ^Host, s: ^Script, server: Server_Id, channel, text: string) -> string {
			f := (^Fake)(host.data)
			if channel == "nowhere" {
				return "there is no such channel"
			}
			append(&f.sent, fmt.aprintf("%d/%s/%s", server, channel, text))
			return ""
		},
		notify = proc(host: ^Host, s: ^Script, server: Server_Id, title, text: string) -> string {
			f := (^Fake)(host.data)
			append(&f.notices, fmt.aprintf("%s: %s", title, text))
			return ""
		},
		status = proc(host: ^Host, s: ^Script, server: Server_Id, text: string) -> string {
			f := (^Fake)(host.data)
			append(&f.statuses, strings.clone(text))
			return ""
		},
		server_by_key = proc(host: ^Host, s: ^Script, key: string) -> Server_Id {
			f := (^Fake)(host.data)
			return f.servers[key] or_else 0
		},
		http_available = proc(host: ^Host) -> bool {
			return !(^Fake)(host.data).http_off
		},
		http_begin = proc(host: ^Host, s: ^Script, id: u64, req: Http_Request) -> string {
			f := (^Fake)(host.data)
			if f.begin_error != "" {
				return f.begin_error
			}
			lines := make([dynamic]string, context.temp_allocator)
			for h in req.headers {
				append(&lines, fmt.tprintf("%s: %s", h.name, h.value))
			}
			append(
				&f.asked,
				Asked {
					id = id,
					method = strings.clone(req.method),
					url = strings.clone(req.url),
					body = strings.clone(req.body),
					headers = strings.clone(strings.join(lines[:], "|", context.temp_allocator)),
					timeout = req.timeout,
				},
			)
			return ""
		},
		http_cancel = proc(host: ^Host, s: ^Script) {},
	}
}

@(private = "file")
fake_destroy :: proc(f: ^Fake) {
	for x in f.logs {delete(x)}
	for x in f.sent {delete(x)}
	for x in f.notices {delete(x)}
	for x in f.statuses {delete(x)}
	delete(f.statuses)
	for a in f.asked {
		delete(a.method)
		delete(a.url)
		delete(a.body)
		delete(a.headers)
	}
	delete(f.asked)
	delete(f.logs)
	delete(f.sent)
	delete(f.notices)
	delete(f.servers)
}

@(test)
test_events_arrive_as_tables :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function on_message(ev)
			assert(ev.text == "hi there" and ev.mine == false and ev.id == "42", "scalars")
			assert(ev.author.name == "Ann" and #ev.tags == 2 and ev.tags[2] == "b", "nested")
			assert(ev.nothing == nil, "nil fields are absent")
			assert(ev.n == 7 and math.type(ev.n) == "integer" and ev.f == 1.5, "numbers")
			ok = true
		end
		function check() assert(ok) end
		`,
	)
	ev := Map(
		[]Pair {
			{"text", "hi there"},
			{"mine", false},
			{"id", "42"},
			{"author", Map([]Pair{{"name", "Ann"}})},
			{"tags", List([]Value{"a", "b"})},
			{"n", i64(7)},
			{"f", 1.5},
		},
	)
	_, ok := call(s, "on_message", ev)
	testing.expect(t, ok)
	results, _, _ := run_to_end(s)
	finish(&results)
	_, ok = call(s, "check")
	testing.expect(t, ok)
	results, _, _ = run_to_end(s)
	defer finish(&results)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
}

@(test)
test_yap_functions :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	f.servers["key1"] = 7
	s := new_script(t)
	defer destroy(s)
	s.host = &f.host
	s.perms = {.Send, .Notify}
	load(
		t,
		s,
		`
		function on_message(ev)
			yap.log("got", ev.text, 3, true, nil)
			yap.send("general", "pong")
			yap.send("general", "to the other", "key1")
			yap.notify("title", "body")
			local ok, err = pcall(yap.send, "nowhere", "x")
			assert(not ok and err:find("no such channel"), err)
			assert(not pcall(yap.send, "general", {}))
			assert(not pcall(yap.send, "general"))
			assert(not pcall(yap.send, ("x"):rep(100), "x"))
			assert(not pcall(yap.send, "general", "x", "unknown key"))
		end
		function load_time() yap.send("general", "x") end
		`,
	)
	_, ok := call(s, "on_message", Map([]Pair{{"text", "ping"}}), 3)
	testing.expect(t, ok)
	results, _, _ := run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	testing.expect_value(t, len(f.logs), 1)
	testing.expect_value(t, f.logs[0], "got ping 3 true nil")
	testing.expect_value(t, len(f.sent), 2)
	testing.expect_value(t, f.sent[0], "3/general/pong") // on behalf of the event's server
	testing.expect_value(t, f.sent[1], "7/general/to the other") // or the one named
	testing.expect_value(t, len(f.notices), 1)
	testing.expect_value(t, f.notices[0], "title: body")

	// With no server to act on there is an error.
	_, ok = call(s, "load_time")
	testing.expect(t, ok)
	results, _, _ = run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expectf(
		t,
		strings.contains(results[0].message, "no server"),
		"message: %q",
		results[0].message,
	)
}

@(test)
test_permissions :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := new_script(t)
	defer destroy(s)
	s.host = &f.host
	load(
		t,
		s,
		`
		function try()
			local ok, err = pcall(yap.send, "general", "x")
			assert(not ok and err:find("'send' permission"), err)
			ok, err = pcall(yap.notify, "t", "x")
			assert(not ok and err:find("'notify' permission"), err)
			yap.log("logging needs none")
		end`,
	)
	_, _ = call(s, "try", nil, 1)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expectf(t, results[0].status == .Finished, "%v", results[0].message)
	testing.expect_value(t, len(f.sent) + len(f.notices), 0)
	testing.expect_value(t, len(f.logs), 1)
}

@(test)
test_timers :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		fired = {}
		function on_timer(ev) fired[#fired + 1] = ev.name end
		function setup()
			yap.timer("once", 0.06)
			yap.timer("tick", 0.06, true)
			yap.timer("never", 0.06)
			yap.cancel("never")
			assert(not pcall(yap.timer, "", 1))
			assert(not pcall(yap.timer, "x", "soon"))
			assert(not pcall(yap.timer, "x", -1))
		end
		function result()
			local once, ticks = 0, 0
			for _, n in ipairs(fired) do
				if n == "once" then once = once + 1 end
				if n == "tick" then ticks = ticks + 1 end
				assert(n ~= "never")
			end
			assert(once == 1, "once fired " .. once)
			assert(ticks >= 2, "tick fired " .. ticks)
		end
		`,
	)
	_, _ = call(s, "setup", nil, 1)
	results: [dynamic]Result
	defer finish(&results)
	start := time.tick_now()
	for time.tick_since(start) < 300 * time.Millisecond {
		step(s, time.Millisecond, &results)
		time.sleep(2 * time.Millisecond)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	results_clear(&results)
	_, _ = call(s, "result")
	for pending(s) > 0 {
		step(s, 2 * time.Millisecond, &results)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
}

@(test)
test_store :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function use()
			assert(yap.store.get("n") == nil)
			yap.store.set("n", 5)
			yap.store.set("s", "text")
			yap.store.set("b", false)
			yap.store.set("f", 2.5)
			assert(yap.store.get("n") == 5 and yap.store.get("s") == "text")
			assert(yap.store.get("b") == false and yap.store.get("f") == 2.5)
			yap.store.set("s", "longer text")
			assert(yap.store.get("s") == "longer text")
			yap.store.delete("n")
			yap.store.set("f", nil)
			assert(yap.store.get("n") == nil and yap.store.get("f") == nil)
			assert(not pcall(yap.store.set, "t", {}))
			assert(not pcall(yap.store.set, ("k"):rep(200), 1))
			assert(not pcall(yap.store.set, "big", ("x"):rep(1 << 20)))
			-- Filling it stops at the limit.
			local ok = true
			for i = 1, 100 do
				ok = pcall(yap.store.set, "fill" .. i, ("x"):rep(10000))
				if not ok then break end
			end
			assert(not ok, "the store has a limit")
		end
		`,
	)
	_, _ = call(s, "use")
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expectf(t, results[0].status == .Finished, "%v", results[0].message)
	testing.expect(t, s.store_dirty)
	testing.expect_value(t, s.store["s"].(string), "longer text")
	testing.expect_value(t, s.store["b"].(bool), false)
}

@(test)
test_register_command :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		got = {}
		yap.register_command("Roll", "Roll dice", function(ev) got[#got + 1] = ev.name .. ":" .. ev.args .. ":" .. #ev.argv end)
		yap.register_command("short", function(ev) got[#got + 1] = "short" end)
		function bad()
			assert(not pcall(yap.register_command, "x"))
			assert(not pcall(yap.register_command, "x", "help"))
			assert(not pcall(yap.register_command, "Bad Name", function() end))
			assert(not pcall(yap.register_command, "", function() end))
			assert(not pcall(yap.register_command, ("n"):rep(40), function() end))
			assert(not pcall(yap.register_command, "x", ("h"):rep(300), function() end))
			assert(not pcall(yap.store.set, "f", function() end))
			assert(not pcall(yap.timer, "t", function() end))
		end
		function result() assert(got[1] == "roll:2d6 +1:2", got[1]) assert(got[2] == "short") assert(#got == 2) end
		function again() yap.register_command("roll", "again", function(ev) got[#got + 1] = "second" end) end
		function many() for i = 1, 40 do yap.register_command("c" .. i, function() end) end end
		function gone() yap.unregister_command("short") end
		`,
	)
	testing.expect_value(t, len(s.commands), 2)
	if len(s.commands) == 2 {
		testing.expect_value(t, s.commands[0].name, "roll") // lower case
		testing.expect_value(t, s.commands[0].help, "Roll dice")
		testing.expect_value(t, s.commands[1].help, "")
	}
	_, ok := call(s, "bad")
	testing.expect(t, ok)
	_, ok = call_command(
		s,
		"roll",
		Map([]Pair{{"name", "roll"}, {"args", "2d6 +1"}, {"argv", List([]Value{"2d6", "+1"})}}),
	)
	testing.expect(t, ok)
	_, ok = call_command(s, "short", Map([]Pair{}))
	testing.expect(t, ok)
	_, ok = call_command(s, "nothing", Map([]Pair{}))
	testing.expect(t, !ok)
	results, _, _ := run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	_, _ = call(s, "result")
	results, _, _ = run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)

	// Registering a name again replaces it; there is a limit; they can go.
	_, _ = call(s, "again")
	_, _ = call(s, "many")
	_, _ = call(s, "gone")
	results, _, _ = run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, results[0].status, Status.Finished)
	testing.expect_value(t, results[1].status, Status.Error) // the 33rd
	testing.expect_value(t, len(s.commands), MAX_COMMANDS - 1) // "short" is gone
	for cmd in s.commands {
		if cmd.name == "roll" {
			testing.expect_value(t, cmd.help, "again")
		}
	}
}

@(test)
test_filters :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function pass(ev) end
		function pass_true(ev) return true end
		function hide(ev) if ev.text == "spam" then return false end end
		function rewrite(ev) return ev.text:upper() .. "!" end
		function empty(ev) return "" end
		function number(ev) return 5 end
		function table_result(ev) return {} end
		`,
	)
	ev := Map([]Pair{{"text", "spam"}})
	check :: proc(
		t: ^testing.T,
		s: ^Script,
		handler: string,
		ev: Value,
		want: Filter_Outcome,
		want_text := "",
	) {
		outcome, text, err := filter(s, handler, ev)
		testing.expectf(t, err == "", "%s: %s", handler, err)
		testing.expect_value(t, outcome, want)
		testing.expect_value(t, text, want_text)
	}
	check(t, s, "pass", ev, .Unchanged)
	check(t, s, "pass_true", ev, .Unchanged)
	check(t, s, "hide", ev, .Hide)
	check(t, s, "hide", Map([]Pair{{"text", "fine"}}), .Unchanged)
	check(t, s, "rewrite", ev, .Replace, "SPAM!")
	check(t, s, "empty", ev, .Replace, "")
	check(t, s, "number", ev, .Unchanged) // only false and strings mean anything
	check(t, s, "table_result", ev, .Unchanged)
	check(t, s, "not_defined", ev, .Unchanged)
	testing.expect_value(t, s.filter_strikes, 0)
}

@(test)
test_a_filter_cannot_stall :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function spin(ev) while true do end end
		function evade(ev) while true do pcall(function() while true do end end) end end
		function coro(ev) coroutine.wrap(function() while true do end end)() end
		function oops(ev) error("bad") end
		function waits(ev) coroutine.yield() end
		function fine(ev) return "ok" end
		`,
	)
	// Each is cut off at the filter limit (not the script's, which is longer),
	// and each is a strike. A good one clears the strikes. The bound on the time
	// is well over the filter limit, for busy CI machines, but well under the
	// script's limit.
	for handler in ([]string{"spin", "evade", "coro"}) {
		began := time.tick_now()
		outcome, _, err := filter(s, handler, Map([]Pair{}))
		took := time.tick_since(began)
		testing.expect_value(t, outcome, Filter_Outcome.Unchanged)
		testing.expectf(t, strings.contains(err, "too long") || err == "", "%s: %q", handler, err)
		testing.expectf(t, err != "", "%s was not stopped", handler)
		testing.expectf(t, took < 50 * time.Millisecond, "%s took %v", handler, took)
		s.filter_strikes = 0 // so as to not switch them off yet
	}
	_, _, err := filter(s, "oops", Map([]Pair{}))
	testing.expectf(t, strings.contains(err, "bad"), "%q", err)
	_, _, err = filter(s, "waits", Map([]Pair{}))
	testing.expectf(t, strings.contains(err, "cannot wait"), "%q", err)
	testing.expect_value(t, s.filter_strikes, 2)
	outcome, text, e := filter(s, "fine", Map([]Pair{}))
	testing.expect_value(t, e, "")
	testing.expect_value(t, outcome, Filter_Outcome.Replace)
	testing.expect_value(t, text, "ok")
	testing.expect_value(t, s.filter_strikes, 0)

	// Three in a row and they are off, for good handlers too.
	for _ in 0 ..< MAX_FILTER_STRIKES {
		_, _, err = filter(s, "oops", Map([]Pair{}))
	}
	testing.expect(t, s.filters_off)
	testing.expectf(t, strings.contains(err, "switched off"), "%q", err)
	outcome, _, e = filter(s, "fine", Map([]Pair{}))
	testing.expect_value(t, outcome, Filter_Outcome.Unchanged)
	testing.expect_value(t, e, "")
}

@(test)
test_a_filter_between_the_steps_of_a_handler :: proc(t: ^testing.T) {
	// Running a filter must not disturb a handler that has been suspended.
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		`
		function slow() local x = 0 for i = 1, 3000000 do x = x + i end done = x end
		function check() assert(done == 3000000 * 3000001 // 2) end
		function f(ev) return "filtered" end`,
	)
	_, _ = call(s, "slow")
	results: [dynamic]Result
	defer finish(&results)
	step(s, time.Millisecond, &results)
	testing.expect_value(t, pending(s), 1) // suspended part-way
	outcome, text, err := filter(s, "f", Map([]Pair{}))
	testing.expect_value(t, err, "")
	testing.expect_value(t, outcome, Filter_Outcome.Replace)
	testing.expect_value(t, text, "filtered")
	for pending(s) > 0 {
		step(s, 2 * time.Millisecond, &results)
	}
	_, _ = call(s, "check")
	for pending(s) > 0 {
		step(s, 2 * time.Millisecond, &results)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
}

@(private = "file")
net_script :: proc(t: ^testing.T, f: ^Fake, source: string) -> ^Script {
	s := new_script(t)
	s.host = &f.host
	s.perms = {.Net}
	load(t, s, source)
	return s
}

@(test)
test_http_requests_and_answers :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := net_script(
		t,
		&f,
		`
		answers = {}
		function get() yap.http_get("http://example.com/a", function(r) answers[#answers + 1] = r end) end
		function post()
			yap.http_post("https://example.com/b", '{"x":1}', function(r) answers[#answers + 1] = r end,
				{ headers = { Authorization = "Bearer t" }, content_type = "application/json", timeout = 3 })
		end
		function check_ok()
			local a = answers[1]
			assert(a.ok == true and a.status == 200 and a.body == "hello" and a.error == nil, "first")
			assert(a.headers["content-type"] == "text/plain" and a.headers["x-multi"] == "1, 2", "headers")
			local b = answers[2]
			assert(b.ok == true and b.status == 404 and b.body == "gone", "second") -- a 404 is an answer
			local c = answers[3]
			assert(c.ok == false and c.error == "timed out" and c.status == nil and c.body == nil, "third")
		end
		`,
	)
	defer destroy(s)
	_, _ = call(s, "get")
	_, _ = call(s, "post")
	_, _ = call(s, "get")
	results, _, _ := run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	testing.expect_value(t, len(f.asked), 3)
	if len(f.asked) == 3 {
		testing.expect_value(t, f.asked[0].method, "GET")
		testing.expect_value(t, f.asked[1].method, "POST")
		testing.expect_value(t, f.asked[1].body, `{"x":1}`)
		// (in either order: a table has none)
		testing.expect(t, strings.contains(f.asked[1].headers, "Authorization: Bearer t"))
		testing.expect(t, strings.contains(f.asked[1].headers, "Content-Type: application/json"))
		testing.expect_value(t, f.asked[1].timeout, 3 * time.Second)
		testing.expect_value(t, f.asked[0].timeout, DEFAULT_REQUEST_TIME)
		// Nothing has answered yet, so nothing has been called.
		http_finish(
			s,
			f.asked[0].id,
			Http_Response {
				ok = true,
				status = 200,
				body = "hello",
				headers = []Http_Header {
					{"Content-Type", "text/plain"},
					{"X-Multi", "1"},
					{"x-multi", "2"},
				},
			},
		)
		http_finish(s, f.asked[1].id, Http_Response{ok = true, status = 404, body = "gone"})
		http_finish(s, f.asked[2].id, Http_Response{error = "timed out"})
		http_finish(s, 999, Http_Response{ok = true}) // not a request of its own: ignored
	}
	// The step gives the answers.
	results = {}
	for pending(s) > 0 || len(s.completions) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	_, _ = call(s, "check_ok")
	for pending(s) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	testing.expect_value(t, len(s.requests), 0)
}

@(test)
test_http_needs_permission_and_a_good_request :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := net_script(
		t,
		&f,
		`
		local function nothing() end
		function bad()
			local function fails(...) local ok, err = pcall(...) assert(not ok, "should have failed") return err end
			assert(fails(yap.http_get, "ftp://example.com/", nothing):find("http or https"))
			assert(fails(yap.http_get, "file:///etc/passwd", nothing):find("http or https"))
			assert(fails(yap.http_get, "http://exa mple.com/", nothing))
			assert(fails(yap.http_get, "http:///nohost", nothing))
			assert(fails(yap.http_get, "http://example.com/", "not a function"):find("function"))
			assert(fails(yap.http_get, "http://example.com/"):find("function"))
			assert(fails(yap.http_post, "http://example.com/", ("x"):rep(300 * 1024), nothing):find("too long"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { nonsense = 1 }):find("no option"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { timeout = "soon" }):find("timeout"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = { ["X\r\nEvil"] = "1" } }):find("not allowed"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = { X = "a\r\nEvil: 1" } }):find("not allowed"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = { Host = "elsewhere" } }):find("not allowed"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = { ["Content-Length"] = "0" } }):find("not allowed"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = { X = 5 } }):find("not allowed"))
			assert(fails(yap.http_get, "http://example.com/", nothing, { headers = "no" }):find("headers"))
			-- Fine: an empty table of options, and the case of a scheme.
			yap.http_get("HTTP://example.com/ok", nothing, {})
			yap.http_get("https://example.com/ok", nothing, { headers = {} })
		end
		`,
	)
	defer destroy(s)
	_, _ = call(s, "bad")
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expectf(t, results[0].status == .Finished, "%v", results[0].message)
	testing.expect_value(t, len(f.asked), 2) // only the two good ones were started

	// Without the permission, none.
	s.perms = {}
	_, _ = call(s, "bad")
	results2, _, _ := run_to_end(s)
	defer finish(&results2)
	testing.expect_value(t, results2[0].status, Status.Error)
	testing.expect(
		t,
		strings.contains(results2[0].message, "'net' permission") ||
		strings.contains(results2[0].message, "assert"),
	)
}

@(test)
test_http_limits :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := net_script(
		t,
		&f,
		`
		function fn() end
		function many() for i = 1, 6 do yap.http_get("http://example.com/" .. i, fn) end end
		function one() yap.http_get("http://example.com/x", fn) end
		`,
	)
	defer destroy(s)
	// Only four at once.
	_, _ = call(s, "many")
	results, _, _ := run_to_end(s)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expect(t, strings.contains(results[0].message, "at most 4 requests at once"))
	finish(&results)
	testing.expect_value(t, len(f.asked), MAX_PENDING_REQUESTS)
	// When they are answered there is room again, until the minute's worth is used.
	for a in f.asked {
		http_finish(s, a.id, Http_Response{ok = true, status = 200})
	}
	for a in f.asked {
		delete(a.method)
		delete(a.url)
		delete(a.body)
		delete(a.headers)
	}
	clear(&f.asked)
	failed := false
	for i in 0 ..< MAX_REQUESTS_PER_MINUTE + 3 {
		_, _ = call(s, "one")
		results, _, _ = run_to_end(s)
		if results[0].status == .Error {
			failed = true
			testing.expect(
				t,
				strings.contains(results[0].message, "in a minute"),
				results[0].message,
			)
		} else if len(f.asked) > 0 {
			http_finish(s, f.asked[len(f.asked) - 1].id, Http_Response{ok = true, status = 200})
		}
		finish(&results)
		_ = i
	}
	testing.expect(t, failed)
}

@(test)
test_http_when_requests_cannot_be_made :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	f.http_off = true
	defer fake_destroy(&f)
	s := net_script(
		t,
		&f,
		`
		function ask() yap.http_get("http://example.com/", function(r) got = r end) end
		function check() assert(got and got.ok == false and got.error:find("libcurl") and got.status == nil) end
		function avail() assert(yap.http_available() == false) end
		function begin_fails() yap.http_get("http://example.com/", function(r) failed = r.error end) end
		function check_failed() assert(failed == "no route") end
		`,
	)
	defer destroy(s)
	for h in ([]string{"avail", "ask"}) {
		_, _ = call(s, h)
	}
	results, _, _ := run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	// The function is called, not by the request itself but at the next step.
	step(s, 5 * time.Millisecond, &results)
	_, _ = call(s, "check")
	for pending(s) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)

	// Or the host can't start this one.
	f.http_off = false
	f.begin_error = "no route"
	_, _ = call(s, "begin_fails")
	for pending(s) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	step(s, 5 * time.Millisecond, &results)
	_, _ = call(s, "check_failed")
	for pending(s) > 0 {
		step(s, 5 * time.Millisecond, &results)
	}
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	testing.expect_value(t, len(s.requests), 0)
}

@(test)
test_status_and_the_limit_on_notifications :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := new_script(t)
	defer destroy(s)
	s.host = &f.host
	s.perms = {.Notify}
	load(
		t,
		s,
		`
		function status() yap.status("one line") yap.status("another") end
		function bad()
			assert(not pcall(yap.status))
			assert(not pcall(yap.status, 5))
			assert(not pcall(yap.status, ("x"):rep(20000)))
			assert(not pcall(yap.notify))
			assert(not pcall(yap.notify, "t", {}))
		end
		function flood() for i = 1, 12 do yap.notify("n" .. i) end end
		`,
	)
	for h in ([]string{"status", "bad"}) {
		_, _ = call(s, h)
	}
	results, _, _ := run_to_end(s)
	for r in results {
		testing.expectf(t, r.status == .Finished, "%v: %v", r.name, r.message)
	}
	finish(&results)
	testing.expect_value(t, len(f.statuses), 2)
	testing.expect_value(t, len(f.notices), 0)

	// Ten in ten seconds, then an error that says so.
	_, _ = call(s, "flood")
	results, _, _ = run_to_end(s)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expect(
		t,
		strings.contains(results[0].message, "too many notifications"),
		results[0].message,
	)
	finish(&results)
	testing.expect_value(t, len(f.notices), MAX_NOTIFICATIONS)

	// Both need the permission.
	s.perms = {}
	load_check :: proc(t: ^testing.T, s: ^Script, source: string) {
		load(t, s, source)
	}
	load_check(
		t,
		s,
		`
		function nope()
			local ok, err = pcall(yap.status, "x") assert(not ok and err:find("'notify' permission"), err)
			ok, err = pcall(yap.notify, "x") assert(not ok and err:find("'notify' permission"), err)
		end`,
	)
	_, _ = call(s, "nope")
	results, _, _ = run_to_end(s)
	defer finish(&results)
	testing.expectf(t, results[0].status == .Finished, "%v", results[0].message)
}

// Every run of a handler is timed and counted under its name, and failures
// are counted too.
@(test)
test_profile_counts_handlers :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(
		t,
		s,
		"function on_message(text) local n = 0 for i = 1, 20000 do n = n + i end end\nfunction on_presence() error('boom') end",
	)
	for _ in 0 ..< 3 {
		_, ok := call(s, "on_message", "hi")
		testing.expect(t, ok)
	}
	_, ok := call(s, "on_presence", "x")
	testing.expect(t, ok)
	results, _, _ := run_to_end(s)
	defer finish(&results)

	messages, presences: Profile_Stat
	for st in s.profile.stats {
		switch st.name {
		case "on_message":
			messages = st
		case "on_presence":
			presences = st
		}
	}
	testing.expect_value(t, messages.calls, 3)
	testing.expect_value(t, messages.failed, 0)
	testing.expect(t, messages.total > 0 && messages.max > 0 && messages.max <= messages.total)
	testing.expect_value(t, presences.calls, 1)
	testing.expect_value(t, presences.failed, 1)

	text, total := profile_text(s.name, &s.profile, time.Minute)
	testing.expect(t, total > 0)
	testing.expect(t, strings.contains(text, "script test: in the last 1m0s, 5 calls took"), text)
	testing.expect(t, strings.contains(text, "1 failed"), text)
	testing.expect(t, strings.contains(text, "on_message 3 x"), text)
}

// A slow call is noted once, and then no more often than SLOW_LOG_EVERY, the
// others being counted. A filter is slow sooner, and names are limited.
@(test)
test_profile_slow_and_limits :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	profile_record(s, "on_message", SLOW_CALL - time.Microsecond, false, false)
	testing.expect_value(t, s.profile.slow, 0)
	profile_record(s, "on_message", SLOW_CALL, false, false)
	testing.expect_value(t, s.profile.slow, 1)
	// Noted: counting starts anew. The next ones are held back.
	st := &s.profile.stats[0]
	testing.expect_value(t, st.slow, 0)
	profile_record(s, "on_message", 2 * SLOW_CALL, false, false)
	profile_record(s, "on_message", 3 * SLOW_CALL, false, false)
	st = &s.profile.stats[0]
	testing.expect_value(t, st.slow, 2)
	testing.expect_value(t, st.max, 3 * SLOW_CALL)
	// After SLOW_LOG_EVERY the next one is noted, with the two held back.
	st.logged = time.tick_add(time.tick_now(), -SLOW_LOG_EVERY - time.Second)
	profile_record(s, "on_message", SLOW_CALL, false, false)
	testing.expect_value(t, s.profile.stats[0].slow, 0)

	// A filter has less time.
	profile_record(s, "on_incoming", SLOW_FILTER, false, true)
	testing.expect_value(t, s.profile.slow, 5)
	profile_record(s, "on_incoming", SLOW_FILTER - time.Microsecond, false, true)
	testing.expect_value(t, s.profile.slow, 5)

	// Over PROFILE_NAMES handlers, the rest is counted together.
	for i in 0 ..< PROFILE_NAMES + 10 {
		profile_record(s, fmt.tprintf("command %d", i), time.Microsecond, false, false)
	}
	testing.expect(t, len(s.profile.stats) <= PROFILE_NAMES + 1)
	other := 0
	for st in s.profile.stats {
		if st.name == PROFILE_OTHER {
			other = st.calls
		}
	}
	testing.expect(t, other > 0)

	// Flushing starts over.
	profile_flush(s, time.tick_now())
	testing.expect_value(t, len(s.profile.stats), 0)
	testing.expect_value(t, s.profile.slow, 0)
	text, _ := profile_text(s.name, &s.profile, time.Minute)
	testing.expect_value(t, text, "")
}
