#+build windows
package server

import win "core:sys/windows"

// disk_free returns how many bytes may still be written to the file system
// that `path` is on.
disk_free :: proc(path: string) -> (bytes: u64, ok: bool) {
	free: win.ULARGE_INTEGER
	if !win.GetDiskFreeSpaceExW(
		win.utf8_to_wstring(path, context.temp_allocator),
		&free,
		nil,
		nil,
	) {
		return
	}
	return u64(free), true
}
