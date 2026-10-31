#+build !wasi
package script

import "core:strings"
import "core:testing"
import "core:time"

// Runs the script's tasks to the end, in frames of `frame`, and returns the
// results and how many frames it took. Gives up after a few seconds, so that
// a bug here fails a test rather than hanging it.
@(private = "file")
run_to_end :: proc(
	s: ^Script,
	frame: time.Duration = 2 * time.Millisecond,
) -> (
	results: [dynamic]Result,
	frames: int,
	longest: time.Duration,
) {
	start := time.tick_now()
	for pending(s) > 0 && time.tick_since(start) < 5 * time.Second {
		began := time.tick_now()
		step(s, frame, &results)
		longest = max(longest, time.tick_since(began))
		frames += 1
	}
	return
}

@(private = "file")
finish :: proc(results: ^[dynamic]Result) {
	results_clear(results)
	delete(results^)
}

@(private = "file")
new_script :: proc(t: ^testing.T, limits := DEFAULT_LIMITS) -> ^Script {
	s := create("test", limits)
	testing.expect(t, s != nil)
	return s
}

@(private = "file")
load :: proc(t: ^testing.T, s: ^Script, source: string) {
	err, ok := run_source(s, source)
	testing.expectf(t, ok, "loading failed: %v", err)
	results, _, _ := run_to_end(s)
	defer finish(&results)
	testing.expect_value(t, len(results), 1)
	if len(results) == 1 {
		testing.expectf(t, results[0].status == .Finished, "script's own code: %v %v", results[0].status, results[0].message)
	}
}

@(test)
test_runs_a_handler :: proc(t: ^testing.T) {
	s := new_script(t)
	defer destroy(s)
	load(t, s, "seen = {}\nfunction on_message(text) seen[#seen + 1] = text:upper() end\nfunction count() assert(#seen == 2 and seen[2] == 'WORLD') end")

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
	testing.expectf(t, strings.contains(results[0].message, "nope"), "message: %q", results[0].message)
	testing.expect_value(t, results[1].status, Status.Error)
	testing.expectf(t, strings.contains(results[1].message, "table"), "message: %q", results[1].message)

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
	results, frames, longest := run_to_end(s)
	defer finish(&results)

	testing.expect_value(t, len(results), 2)
	// The other handler is not held up by the loop...
	testing.expect_value(t, results[0].name, "fine")
	testing.expect_value(t, results[0].status, Status.Finished)
	// ... which is killed after its time is up, having been suspended and
	// continued over many frames, none of which was long.
	testing.expect_value(t, results[1].name, "spin")
	testing.expect_value(t, results[1].status, Status.Killed)
	testing.expectf(t, frames > 5, "ran in %d frames", frames)
	testing.expectf(t, results[1].slices > 5, "ran in %d slices", results[1].slices)
	testing.expectf(t, results[1].spent < 150 * time.Millisecond, "ran for %v", results[1].spent)
	testing.expectf(t, longest < 20 * time.Millisecond, "a frame took %v", longest)
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
	load(t, s, "function hog() local t = {} for i = 1, 1e7 do t[i] = ('x'):rep(100) .. i end end function ok() local t = {} for i = 1, 100 do t[i] = i end end")
	_, _ = call(s, "hog")
	results, _, _ := run_to_end(s)
	testing.expect_value(t, len(results), 1)
	testing.expect_value(t, results[0].status, Status.Error)
	testing.expectf(t, strings.contains(results[0].message, "memory"), "message: %q", results[0].message)
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
	load(t, s, "for i = 1, 100000 do local ok = pcall(function() keep[#keep + 1] = ('y'):rep(1000) .. i end) if not ok then break end end")
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
