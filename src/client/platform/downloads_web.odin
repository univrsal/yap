#+build wasi
package platform

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"

// In a browser, saving a picture is a download: the page hands the bytes to the
// browser as a file (web/shell.c), and the browser puts it in its downloads
// folder or asks where to save it, depending on the user's settings. There is no
// path to return, so the name the file was offered under is returned instead.

@(default_calling_convention = "c")
foreign _ {
	// Offers the bytes to the browser as a download called `name`.
	yap_download :: proc(data: [^]u8, size: i32, name: cstring) -> i32 ---
}

// save_to_downloads offers `data` as yap-<random>.<ext>, a unique name like on
// the desktop, and returns that name.
save_to_downloads :: proc(
	data: []u8,
	ext: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	random: [4]u8
	crypto.rand_bytes(random[:])
	name := fmt.tprintf("yap-%s.%s", string(hex.encode(random[:], context.temp_allocator)), ext)
	if yap_download(raw_data(data), i32(len(data)), fmt.ctprint(name)) == 0 {
		return "", false
	}
	return fmt.aprint(name, allocator = allocator), true
}
