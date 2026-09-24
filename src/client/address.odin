package client

import "core:fmt"
import "core:strings"

import "../proto"

/*
with_default_port returns the server address the user typed with
proto.DEFAULT_PORT added if it names no port: "example.com" becomes
"example.com:7777", "[::1]" becomes "[::1]:7777". A WebSocket URL (for
the web client, see transport_web.odin) is left as it is.

It's applied before the address is used for anything, so that it's also
what known_servers and the recent servers are keyed by: "example.com"
and "example.com:7777" are the same server.
*/
with_default_port :: proc(typed: string, allocator := context.temp_allocator) -> string {
	addr := strings.trim_space(typed)
	switch {
	case addr == "", strings.has_prefix(addr, "ws://"), strings.has_prefix(addr, "wss://"):
		return strings.clone(addr, allocator)
	case strings.has_prefix(addr, "["):
		// [IPv6]:port
		if strings.contains(addr, "]:") && !strings.has_suffix(addr, "]:") {
			return strings.clone(addr, allocator)
		}
		addr = strings.trim_suffix(addr, ":")
	case strings.count(addr, ":") > 1:
		// A bare IPv6 address: it can't have a port without brackets.
		addr = strings.concatenate({"[", addr, "]"}, context.temp_allocator)
	case strings.has_suffix(addr, ":"):
		addr = addr[:len(addr) - 1]
	case strings.contains(addr, ":"):
		return strings.clone(addr, allocator)
	}
	return fmt.aprintf("%s:%d", addr, proto.DEFAULT_PORT, allocator = allocator)
}
