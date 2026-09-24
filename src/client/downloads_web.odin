#+build wasi
package client

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"

/*
Saving a picture is a download in a browser: the page hands the bytes to
the browser as a file (web/shell.c), and the browser puts it in its
downloads folder, or asks where, as the person has set it up. There's
no path to hand back, so the name it was offered under stands in for one.
*/

@(default_calling_convention = "c")
foreign _ {
	// Offers the bytes to the browser as a download called `name`.
	yap_download :: proc(data: [^]u8, size: i32, name: cstring) -> i32 ---
}

// save_to_downloads offers `data` as yap-<random>.<ext>, a name of its
// own like on a desktop, and returns that name.
save_to_downloads :: proc(data: []u8, ext: string, allocator := context.allocator) -> (path: string, ok: bool) {
	random: [4]u8
	crypto.rand_bytes(random[:])
	name := fmt.tprintf("yap-%s.%s", string(hex.encode(random[:], context.temp_allocator)), ext)
	if yap_download(raw_data(data), i32(len(data)), fmt.ctprint(name)) == 0 {
		return "", false
	}
	return fmt.aprint(name, allocator = allocator), true
}
