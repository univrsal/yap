package mattermost

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import "common:proto"

// The rules that turn what Mattermost has into what yap can hold (step 3 raised
// yap's limits to Mattermost's, so a value only gets cut if the export was made
// by something that doesn't keep to Mattermost's own). Each function says
// whether it had to cut, so that the report can say so: nothing is shortened
// without being listed.

// cut_text returns `text` cut to at most `limit` bytes, on the boundary of a
// character. `cut` says whether it had to.
cut_text :: proc(text: string, limit: int) -> (kept: string, cut: bool) {
	if len(text) <= limit {
		return text, false
	}
	n := limit
	for n > 0 && !utf8.rune_start(text[n]) {
		n -= 1
	}
	return text[:n], true
}

// clean_text makes a single line of text that yap takes as a name or a topic:
// control and invisible characters go, whitespace becomes a space, the ends
// are trimmed, and it is cut to `limit` bytes. `cut` says that the limit
// shortened it.
clean_text :: proc(
	raw: string,
	limit: int,
	allocator := context.temp_allocator,
) -> (
	text: string,
	cut: bool,
) {
	buf := make([]u8, len(raw), allocator)
	full := proto.sanitize_text(raw, buf)
	text, cut = cut_text(full, limit)
	return strings.trim_space(text), cut
}

// clean_message is clean_text for a message, which keeps its lines.
clean_message :: proc(
	raw: string,
	allocator := context.temp_allocator,
) -> (
	text: string,
	cut: bool,
) {
	// Cleaning a message never makes it longer.
	buf := make([]u8, len(raw), allocator)
	full := proto.sanitize_message(raw, buf)
	return cut_text(full, proto.MAX_CHAT_SIZE)
}

// Suffix_Style is how a name that is already taken is made different.
Suffix_Style :: enum {
	Underscore, // alice_2: for usernames and emoji
	Parens, // General (2): for channels, which are shown to people
}

// Unique makes names that nobody else has, remembering the ones it gave. Names
// are compared in lower case.
Unique :: struct {
	taken:     map[string]bool,
	style:     Suffix_Style,
	allocator: Allocator,
}

unique_make :: proc(style: Suffix_Style, allocator: Allocator) -> Unique {
	return {taken = make(map[string]bool, allocator), style = style, allocator = allocator}
}

// unique_reserve marks a name as taken, for one that is there already.
unique_reserve :: proc(u: ^Unique, name: string) {
	u.taken[strings.to_lower(name, u.allocator)] = true
}

// unique_name returns `name` if nobody has it, and otherwise the first of
// name_2, name_3 ... that nobody has. The result is at most `limit` bytes; the
// name is shortened to make room for the number. It is marked as taken.
unique_name :: proc(u: ^Unique, wanted: string, limit: int) -> string {
	name, _ := cut_text(wanted, limit)
	try :: proc(u: ^Unique, name: string) -> bool {
		key := strings.to_lower(name, context.temp_allocator)
		if key in u.taken {
			return false
		}
		u.taken[strings.clone(key, u.allocator)] = true
		return true
	}
	if try(u, name) {
		return strings.clone(name, u.allocator)
	}
	for n := 2;; n += 1 {
		suffix: string
		switch u.style {
		case .Underscore:
			suffix = fmt.tprintf("_%d", n)
		case .Parens:
			suffix = fmt.tprintf(" (%d)", n)
		}
		base, _ := cut_text(name, limit - len(suffix))
		candidate := strings.concatenate(
			{strings.trim_space(base), suffix},
			context.temp_allocator,
		)
		if try(u, candidate) {
			return strings.clone(candidate, u.allocator)
		}
	}
}
