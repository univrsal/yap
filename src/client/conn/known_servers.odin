package conn

import "core:encoding/hex"
import "core:fmt"
import "core:strings"

import "common:."
import "common:proto"

// A trust-on-first-use store for server keys, similar to ssh's known_hosts. It
// has one `<host:port> <hex public key>` entry per line, keyed by the address
// as the user typed it, but without regard to case (host names and IPv6
// addresses don't have one).

Trust :: enum {
	Known, // the key matches the saved one
	New, // this server has not been seen before
	Mismatch, // the key differs from the saved one, which may mean impersonation
	// The file is there but can't be read. Trusting the key as new would
	// also mean writing a file with only this entry and losing the others.
	Unreadable,
}


check_server_key :: proc(
	path, addr: string,
	key: [proto.KEY_SIZE]byte,
) -> (
	trust: Trust,
	saved: [proto.KEY_SIZE]byte,
) {
	if !common.store_exists(path) {
		return .New, {} // there are no known servers yet
	}
	data, read_ok := common.store_read(path, context.temp_allocator)
	if !read_ok {
		return .Unreadable, {}
	}

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 || !strings.equal_fold(fields[0], addr) {
			continue
		}
		ok: bool
		saved, ok = common.parse_key_hex(fields[1])
		if !ok {
			continue
		}
		return saved == key ? .Known : .Mismatch, saved
	}
	return .New, {}
}

// remember_server_key saves the key for `addr`. The file has one line per
// server, so a new entry is added by reading the existing content and writing
// it back with the new line appended. The file is only a few lines long, and
// this approach works the same for a browser's local storage as for a file
// (see src/common/store.odin).
remember_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	key := key
	line := fmt.tprintf("%s %s\n", addr, string(hex.encode(key[:], context.temp_allocator)))
	existing: string
	if common.store_exists(path) {
		read_ok: bool
		existing, read_ok = common.store_read(path, context.temp_allocator)
		if !read_ok {
			return false // writing would lose the other entries
		}
	}
	return common.store_write(path, strings.concatenate({existing, line}, context.temp_allocator))
}

// A line of the file, used for the list of trusted servers on the settings page.
Known_Server :: struct {
	addr: string,
	key:  [proto.KEY_SIZE]byte,
}

// list_known_servers reads every well-formed line in the file's order.
// Everything it returns is allocated with `allocator`.
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
		key, key_ok := common.parse_key_hex(fields[1])
		if !key_ok {
			continue
		}
		append(&list, Known_Server{addr = strings.clone(fields[0], allocator), key = key})
	}
	return list[:]
}

// forget_server_key removes the saved key of `addr`, so the next connection
// trusts whatever key the server presents, as if it were the first connection.
// All other lines are kept unchanged, including comments.
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
		if len(fields) == 2 && strings.equal_fold(fields[0], addr) {
			continue
		}
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return common.store_write(path, strings.to_string(b))
}

// replace_server_key trusts `key` for `addr` instead of the saved key. It is
// used when the user has decided that a changed key is expected.
replace_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	return forget_server_key(path, addr) && remember_server_key(path, addr, key)
}
