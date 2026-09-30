#+build !wasi
package common

import "core:os"
import log "common:wlog"

// On a desktop the name is a path and these are plain files. A private
// one (the key) is written readable by its owner only.

store_exists :: proc(name: string) -> bool {
	return os.exists(name)
}

store_read :: proc(name: string, allocator := context.allocator) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(name, allocator)
	if err != nil {
		log.errorf("failed to read %s: %v", name, err)
		return "", false
	}
	return string(data), true
}

store_write :: proc(name: string, text: string, private := false) -> bool {
	perms := os.Permissions{.Read_User, .Write_User}
	if !private {
		perms += {.Read_Group, .Read_Other}
	}
	// Some live in a directory of their own (the client's DM history).
	if dir := os.dir(name); dir != "" && !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			log.errorf("failed to create %s: %v", dir, err)
			return false
		}
	}
	if err := os.write_entire_file(name, transmute([]byte)text, perms); err != nil {
		log.errorf("failed to write %s: %v", name, err)
		return false
	}
	return true
}

// store_remove deletes `name`; one that isn't there is already gone.
store_remove :: proc(name: string) -> bool {
	if !os.exists(name) {
		return true
	}
	if err := os.remove(name); err != nil {
		log.errorf("failed to remove %s: %v", name, err)
		return false
	}
	return true
}
