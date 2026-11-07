package main

import "core:strings"
import "core:testing"


// The headless client's commands, read from its source: every one has to be in
// the table (or left out on purpose), so that the hints and the completion do not
// fall behind when a command is added there.
HEADLESS_SOURCE :: #load("../client/headless/commands.odin", string)

@(test)
test_every_headless_command_is_documented :: proc(t: ^testing.T) {
	src := HEADLESS_SOURCE
	found := 0
	for {
		at := strings.index(src, "\"/")
		if at < 0 {
			break
		}
		src = src[at + 2:]
		end := 0
		for end < len(src) && (src[end] >= 'a' && src[end] <= 'z' || src[end] == '-') {
			end += 1
		}
		name := src[:end]
		if len(name) < 2 {
			continue
		}
		found += 1
		_, documented := command_doc(name)
		skipped := false
		for u in UNDOCUMENTED_COMMANDS {
			skipped ||= u == name
		}
		testing.expectf(t, documented || skipped, "/%s is handled by the headless client but is not in COMMAND_DOCS", name)
	}
	testing.expect(t, found > 50, "the source was not read")
}
