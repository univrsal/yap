package script

import "base:runtime"
import "core:c"
import "core:strings"

// A value that passes between the host and a script: what an event hands to a
// handler (a Map, usually) and what the yap.* functions are given and return.
// nil is Lua's nil, and a List is a Lua array.
Value :: union {
	bool,
	i64,
	f64,
	string,
	List,
	Map,
	Function,
}

// A Lua function the script handed over: a reference in its registry, kept
// until released (release). It only comes from scripts (to_c cannot make one).
Function :: distinct i64

List :: distinct []Value
Map :: distinct []Pair

Pair :: struct {
	key:   string,
	value: Value,
}

// The deepest a Value may nest, as in yap_lua.c.
MAX_DEPTH :: 8

// to_c turns a value into the form C pushes into Lua. Everything is allocated
// with `allocator` (an arena, as the C value only has to last for the call),
// and strings are referred to, not copied.
to_c :: proc(v: Value, allocator: runtime.Allocator, depth := 0) -> (out: C_Value) {
	switch x in v {
	case nil:
		out.type = C_NIL
	case bool:
		out.type = C_BOOL
		out.i = 1 if x else 0
	case i64:
		out.type = C_INT
		out.i = c.longlong(x)
	case f64:
		out.type = C_NUM
		out.n = x
	case string:
		out.type = C_STR
		out.s = raw_data(x)
		out.len = c.size_t(len(x))
	case Function:
		out.type = C_NIL
	case List:
		out.type = C_LIST
		if depth >= MAX_DEPTH {
			return {}
		}
		items := make([]C_Value, len(x), allocator)
		for e, i in x {
			items[i] = to_c(e, allocator, depth + 1)
		}
		out.items = raw_data(items)
		out.count = c.size_t(len(x))
	case Map:
		out.type = C_MAP
		if depth >= MAX_DEPTH {
			return {}
		}
		items := make([]C_Value, 2 * len(x), allocator)
		for e, i in x {
			// The keys are used as C strings.
			key, _ := strings.clone_to_cstring(e.key, allocator)
			items[2 * i] = {
				type = C_STR,
				s    = ([^]u8)(key),
				len  = c.size_t(len(e.key)),
			}
			items[2 * i + 1] = to_c(e.value, allocator, depth + 1)
		}
		out.items = raw_data(items)
		out.count = c.size_t(len(x))
	}
	return
}

// from_c reads a value from C: a scalar passed to a host function, or a table a
// script returned. Everything is copied into `allocator`.
from_c :: proc(v: C_Value, allocator: runtime.Allocator) -> Value {
	switch v.type {
	case C_LIST:
		list := make([]Value, int(v.count), allocator)
		for i in 0 ..< int(v.count) {
			list[i] = from_c(v.items[i], allocator)
		}
		return List(list)
	case C_MAP:
		pairs := make([]Pair, int(v.count), allocator)
		for i in 0 ..< int(v.count) {
			key := v.items[2 * i]
			pairs[i] = {
				key   = strings.clone(string(key.s[:key.len]), allocator) if key.len > 0 else "",
				value = from_c(v.items[2 * i + 1], allocator),
			}
		}
		return Map(pairs)
	case C_BOOL:
		return v.i != 0
	case C_INT:
		return i64(v.i)
	case C_NUM:
		return v.n
	case C_STR:
		return strings.clone(string(v.s[:v.len]), allocator) if v.len > 0 else ""
	case C_FUNC:
		return Function(v.i)
	}
	return nil
}

// A map value from pairs; entries whose value is nil are left out, which is
// how a field that has no value is spelled in Lua.
map_of :: proc(pairs: ..Pair, allocator := context.temp_allocator) -> Map {
	kept := make([dynamic]Pair, 0, len(pairs), allocator)
	for p in pairs {
		if p.value != nil {
			append(&kept, p)
		}
	}
	return Map(kept[:])
}
