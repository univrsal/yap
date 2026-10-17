package conn

import "core:fmt"
import "core:strconv"
import "core:strings"

import "common:proto"

// with_default_port returns the server address the user typed, with
// proto.DEFAULT_PORT added if the address has no port: "example.com" becomes
// "example.com:7777" and "[::1]" becomes "[::1]:7777". A WebSocket URL (used by
// the web client, see transport_web.odin) is returned unchanged, and a server's
// web address becomes the address of its relay: "https://chat.example.org"
// becomes "wss://chat.example.org/yap/chat.example.org" (see relay_address).
//
// It is applied before the address is used for anything else, so it is also
// the key for known_servers and the joined servers: "example.com" and
// "example.com:7777" refer to the same server.
with_default_port :: proc(typed: string, allocator := context.temp_allocator) -> string {
	addr := strings.trim_space(typed)
	switch {
	case addr == "", strings.has_prefix(addr, "ws://"), strings.has_prefix(addr, "wss://"):
		return strings.clone(addr, allocator)
	case strings.has_prefix(addr, "https://"), strings.has_prefix(addr, "http://"):
		return relay_address(addr, allocator)
	case strings.has_prefix(addr, "["):
		// [IPv6]:port
		if strings.contains(addr, "]:") && !strings.has_suffix(addr, "]:") {
			return strings.clone(addr, allocator)
		}
		addr = strings.trim_suffix(addr, ":")
	case strings.count(addr, ":") > 1:
		// A bare IPv6 address cannot carry a port without brackets.
		addr = strings.concatenate({"[", addr, "]"}, context.temp_allocator)
	case strings.has_suffix(addr, ":"):
		addr = addr[:len(addr) - 1]
	case strings.contains(addr, ":"):
		return strings.clone(addr, allocator)
	}
	return fmt.aprintf("%s:%d", addr, proto.DEFAULT_PORT, allocator = allocator)
}

// relay_address turns the address of a server's web page into the address of
// the relay that serves it (server/relay.odin), which takes WebSockets under
// /yap/ beside the page: wss:// for an https page, ws:// for an http one. What
// follows /yap/ only names the server in the relay's log, so it is the page's
// host. Anything after the page's path (a query or a fragment) is dropped.
@(private = "file")
relay_address :: proc(page: string, allocator := context.temp_allocator) -> string {
	secure := strings.has_prefix(page, "https://")
	rest := page[len("https://"):] if secure else page[len("http://"):]
	if cut := strings.index_any(rest, "?#"); cut >= 0 {
		rest = rest[:cut]
	}
	rest = strings.trim_right(rest, "/")
	if strings.has_suffix(rest, "/index.html") {
		rest = rest[:len(rest) - len("/index.html")]
	}
	host, _, _ := strings.partition(rest, "/")
	return fmt.aprintf("%s://%s/yap/%s", "wss" if secure else "ws", rest, host, allocator = allocator)
}

// is_web_address is whether `typed` is the address of a server's web page,
// which is how the web client joins a server (see relay_address): http:// or
// https://, then a domain or an IP address and maybe a port, and nothing else
// but what the browser's address bar may add after it (a slash, a query, a
// fragment), so the page's address can be pasted as it is.
is_web_address :: proc(typed: string) -> bool {
	addr := strings.trim_space(typed)
	rest: string
	switch {
	case strings.has_prefix(addr, "https://"):
		rest = addr[len("https://"):]
	case strings.has_prefix(addr, "http://"):
		rest = addr[len("http://"):]
	case:
		return false
	}
	if cut := strings.index_any(rest, "?#"); cut >= 0 {
		rest = rest[:cut]
	}
	rest = strings.trim_suffix(rest, "/")
	host := rest
	if strings.has_prefix(rest, "[") {
		end := strings.index_byte(rest, ']')
		if end < 0 {
			return false
		}
		host = rest[:end + 1]
		rest = rest[end + 1:]
	} else if colon := strings.last_index_byte(rest, ':'); colon >= 0 {
		host = rest[:colon]
		rest = rest[colon:]
	} else {
		rest = ""
	}
	if rest != "" {
		port, ok := strconv.parse_uint(rest[1:], 10)
		if rest[0] != ':' || !ok || port == 0 || port > 65535 {
			return false
		}
	}
	return host != "" && !strings.contains_any(host, "/@ \\")
}
