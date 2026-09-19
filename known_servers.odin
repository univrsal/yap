package yap

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

import "proto"

/*
Trust-on-first-use store for server keys, like ssh's known_hosts: one
`<host:port> <hex public key>` per line. Entries are keyed by the
address exactly as the user typed it.
*/

Trust :: enum {
	Known,    // matches the saved key
	New,      // never seen this server before
	Mismatch, // saved key differs: possible impersonation
}

default_known_servers_path :: proc() -> string {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	path, _ := os.join_path({dir, "yap", "known_servers"}, context.temp_allocator)
	return path
}

check_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> (trust: Trust, saved: [proto.KEY_SIZE]byte) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
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

remember_server_key :: proc(path, addr: string, key: [proto.KEY_SIZE]byte) -> bool {
	dir, _ := os.split_path(path)
	if dir != "" {
		os.make_directory_all(dir)
	}

	f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		fmt.eprintfln("failed to open %s: %v", path, err)
		return false
	}
	defer os.close(f)

	key := key
	line := fmt.tprintf("%s %s\n", addr, string(hex.encode(key[:], context.temp_allocator)))
	if _, err = os.write_string(f, line); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
		return false
	}
	return true
}
