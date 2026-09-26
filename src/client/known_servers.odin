package client

import "core:encoding/hex"
import "core:fmt"
import "core:strings"

import "../common"
import "../proto"

/*
Trust-on-first-use store for server keys, like ssh's known_hosts: one
`<host:port> <hex public key>` per line. Entries are keyed by the
address exactly as the user typed it.
*/

Trust :: enum {
	Known, // matches the saved key
	New, // never seen this server before
	Mismatch, // saved key differs: possible impersonation
}


check_server_key :: proc(
	path, addr: string,
	key: [proto.KEY_SIZE]byte,
) -> (
	trust: Trust,
	saved: [proto.KEY_SIZE]byte,
) {
	if !common.store_exists(path) {
		return .New, {} // no known servers yet
	}
	data, read_ok := common.store_read(path, context.temp_allocator)
	if !read_ok {
		return .New, {}
	}

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 || fields[0] != addr {
			continue
		}
		raw, ok := hex.decode(transmute([]byte)fields[1], context.temp_allocator)
		if !ok || len(raw) != proto.KEY_SIZE {
			continue
		}
		copy(saved[:], raw)
		return saved == key ? .Known : .Mismatch, saved
	}
	return .New, {}
}

/*
The file is a line per server, so a new one goes on by reading what's
there and writing it back with the line added. It's a handful of lines
either way, and this works the same on a browser's local storage as it
does on a file (see src/common/store.odin).
*/
remember_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	key := key
	line := fmt.tprintf("%s %s\n", addr, string(hex.encode(key[:], context.temp_allocator)))
	existing: string
	if common.store_exists(path) {
		existing, _ = common.store_read(path, context.temp_allocator)
	}
	return common.store_write(path, strings.concatenate({existing, line}, context.temp_allocator))
}

// A line of the file, for the settings page's list of trusted servers.
Known_Server :: struct {
	addr: string,
	key:  [proto.KEY_SIZE]byte,
}

// list_known_servers reads every well-formed line, in the file's order.
// Everything it returns is in `allocator`.
list_known_servers :: proc(path: string, allocator := context.allocator) -> []Known_Server {
	if !common.store_exists(path) {
		return nil
	}
	data, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return nil
	}
	list := make([dynamic]Known_Server, allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 {
			continue
		}
		raw, hex_ok := hex.decode(transmute([]byte)fields[1], context.temp_allocator)
		if !hex_ok || len(raw) != proto.KEY_SIZE {
			continue
		}
		entry := Known_Server {
			addr = strings.clone(fields[0], allocator),
		}
		copy(entry.key[:], raw)
		append(&list, entry)
	}
	return list[:]
}

/*
forget_server_key drops the saved key of `addr`, so the next connection
trusts whatever key it's shown, as if it were the first. Every other
line is kept as it was, comments and all.
*/
forget_server_key :: proc(path, addr: string) -> bool {
	if !common.store_exists(path) {
		return true
	}
	data, ok := common.store_read(path, context.temp_allocator)
	if !ok {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 2 && fields[0] == addr {
			continue
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return common.store_write(path, strings.to_string(b))
}

// replace_server_key trusts `key` for `addr` in place of the one saved,
// for when the user has decided a changed key is expected.
replace_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	return forget_server_key(path, addr) && remember_server_key(path, addr, key)
}

// key_hex is a whole public key, for comparing with the one the server
// logs when it starts ("server public key: ...").
key_hex :: proc(key: [proto.KEY_SIZE]byte) -> string {
	key := key
	return string(hex.encode(key[:], context.temp_allocator))
}
