package script

import "core:hash"
import "core:strings"
import "core:time"

// How long a script may take to be read for its get_info: its own code, then the
// function. It is a one-off, and the script has done nothing yet.
INFO_LOAD_TIME :: 500 * time.Millisecond
INFO_CALL_TIME :: 100 * time.Millisecond

// source_hash is what a script's text is known by: the user's approval of a
// script is for this, so that a script that has been changed asks again.
source_hash :: proc(source: string) -> u64 {
	return hash.fnv64a(transmute([]u8)source)
}

// read_info loads a script the way it is when it is only being looked at (every
// yap.* function does nothing, so that its own code can run to the end), and
// asks it who it is with get_info. `has_info` is false for a script without that
// function (its Info is empty). `err` says why a script could not be read at all
// (a syntax error, an endless loop, get_info failing); the Info is empty then too.
read_info :: proc(
	name, source: string,
	allocator := context.allocator,
) -> (
	info: Info,
	has_info: bool,
	err: string,
) {
	s := create(name, Limits{memory = 8 * 1024 * 1024, total = INFO_LOAD_TIME})
	if s == nil {
		return {}, false, "out of memory"
	}
	defer destroy(s)
	s.meta = true
	if e, ok := run_source(s, source); !ok {
		return {}, false, e
	}
	results: [dynamic]Result
	defer {
		results_clear(&results)
		delete(results)
	}
	began := time.tick_now()
	for pending(s) > 0 && time.tick_since(began) < INFO_LOAD_TIME {
		step(s, 5 * time.Millisecond, &results)
	}
	if pending(s) > 0 {
		return {}, false, "its own code takes too long to run"
	}
	for r in results {
		if r.status != .Finished {
			return {}, false, clone_message(r.message)
		}
	}
	value, found, e := call_sync(s, "get_info", nil, 0, INFO_CALL_TIME, context.temp_allocator)
	switch {
	case !found:
		return {}, false, ""
	case e != "":
		return {}, false, clone_message(e)
	}
	return parse_info(value, allocator), true, ""
}

// An error message in the temp allocator, since the script it came from goes.
@(private = "file")
clone_message :: proc(message: string) -> string {
	return strings.clone(message, context.temp_allocator)
}
