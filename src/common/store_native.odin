#+build !wasi
package common

import log "wlog"
import "core:os"

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
	if err := os.write_entire_file(name, transmute([]byte)text, perms); err != nil {
		log.errorf("failed to write %s: %v", name, err)
		return false
	}
	return true
}
