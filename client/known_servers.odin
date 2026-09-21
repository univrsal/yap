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
	data, read_ok := common.store_read(path, context.temp_allocator)
	if !read_ok {
		return .New, {} // missing file == no known servers yet
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
does on a file (see common/store.odin).
*/
remember_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	key := key
	line := fmt.tprintf("%s %s\n", addr, string(hex.encode(key[:], context.temp_allocator)))
	existing, _ := common.store_read(path, context.temp_allocator)
	return common.store_write(path, strings.concatenate({existing, line}, context.temp_allocator))
}
