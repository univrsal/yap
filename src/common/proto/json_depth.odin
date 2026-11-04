package proto

// core:encoding/json recurses once per level of nesting (its validator and
// its parser both do), with no limit, so a body of a few hundred kilobytes of
// `[` overflows the stack of the thread that parses it. Everything that
// parses JSON that somebody else wrote checks its nesting first.

// JSON_MAX_DEPTH is how deeply nested JSON from the network may be. The
// bodies the API takes are objects of scalars and lists of such objects.
JSON_MAX_DEPTH :: 32

// json_nesting_ok says whether `data` nests arrays and objects at most
// `limit` deep. It only counts brackets (outside of strings), so it doesn't
// say that the text is valid JSON, and a text that is nested too deeply is
// refused without being looked at any further.
@(require_results)
json_nesting_ok :: proc(data: []u8, limit := JSON_MAX_DEPTH) -> bool {
	depth := 0
	in_string, escaped := false, false
	for b in data {
		if in_string {
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				in_string = false
			}
			continue
		}
		switch b {
		case '"':
			in_string = true
		case '[', '{':
			depth += 1
			if depth > limit {
				return false
			}
		case ']', '}':
			depth = max(depth - 1, 0)
		}
	}
	return true
}
