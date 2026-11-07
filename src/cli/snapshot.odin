package main

import "core:fmt"
import "core:strings"
import "core:sync"

import "client:conn"

// snapshot says what the view shows as text: how far the connection is, and the
// channels with what is unread in them. It is the temporary stand-in for the
// screens. `failed` is set when the connection is over and will not come back
// by itself. The text is allocated with the context's allocator.
snapshot :: proc(v: ^conn.View) -> (text: string, failed: bool) {
	b: strings.Builder
	sync.guard(&v.mutex)
	name := v.server_name if v.server_name != "" else v.server
	switch v.status {
	case .Disconnected:
		fmt.sbprintfln(&b, "%s: disconnected", name)
	case .Connecting:
		fmt.sbprintfln(&b, "%s: connecting...", name)
	case .Failed:
		fmt.sbprintfln(&b, "%s: %s%s", name, v.error, " (trying again)" if v.retrying else "")
		failed = !v.retrying
	case .Connected:
		fmt.sbprintfln(&b, "%s: connected", name)
		switch v.login.state {
		case .Needed:
			fmt.sbprintfln(
				&b,
				"  this device is not logged in: pass -user and -user-password%s",
				fmt.tprintf(" (%s)", v.login.error) if v.login.error != "" else "",
			)
		case .Unknown, .Working:
		case .Done:
			fmt.sbprintfln(&b, "  logged in as %s", v.my_name)
			if v.login.must_change {
				fmt.sbprintln(&b, "  the password has to be changed first")
			}
		}
		for ch in v.channels {
			fmt.sbprintf(&b, "  #%s", ch.name)
			if ch.unread > 0 {
				fmt.sbprintf(&b, "  %d unread", ch.unread)
			}
			if ch.mentions > 0 {
				fmt.sbprintf(&b, ", %d mentions", ch.mentions)
			}
			if ch.topic != "" {
				fmt.sbprintf(&b, "  - %s", ch.topic)
			}
			fmt.sbprintln(&b)
		}
	}
	return strings.to_string(b), failed
}
