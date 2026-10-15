#+build !windows
package server

import "core:strings"
import "core:sys/posix"

// disk_free returns how many bytes may still be written to the file system
// that `path` is on.
disk_free :: proc(path: string) -> (bytes: u64, ok: bool) {
	st: posix.statvfs_t
	if posix.statvfs(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return
	}
	return u64(st.f_bavail) * u64(st.f_frsize), true
}
