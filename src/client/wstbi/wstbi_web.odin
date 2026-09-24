#+build wasi
/*
The web half of the image decoder: stb_image.c compiled by emscripten
alongside the client (see web/build.sh), bound here as plain C symbols.
*/
package wstbi

import "core:c"

@(default_calling_convention = "c", link_prefix = "stbi_")
foreign _ {
	info_from_memory :: proc(buffer: [^]byte, len: c.int, x, y, comp: ^c.int) -> c.int ---
	load_from_memory :: proc(buffer: [^]byte, len: c.int, x, y, channels_in_file: ^c.int, desired_channels: c.int) -> [^]byte ---
	image_free :: proc(retval_from_load: rawptr) ---
	failure_reason :: proc() -> cstring ---
}
