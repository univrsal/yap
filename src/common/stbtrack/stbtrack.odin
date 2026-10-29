#+build !wasi
// stb_image, with the pictures it decodes counted by memtrack.
//
// stb_image mallocs the decoded pixels itself and hands them over, so
// nothing can see them go by. These procedures call vendor:stb/image and
// tell memtrack about the pixels (the large part; what stb_image allocates
// and frees while it decodes is short-lived and not counted) until
// image_free. Use them instead of the vendor ones for anything that is
// freed with image_free.
package stbtrack

import "base:runtime"
import "core:c"
import stbi "vendor:stb/image"

import "common:memtrack"

@(private)
SITE := runtime.Source_Code_Location {
	file_path = "stb_image",
	procedure = "decoded pictures",
}

// load_from_memory is stbi.load_from_memory.
load_from_memory :: proc(
	buffer: [^]byte,
	len: c.int,
	x, y, channels_in_file: ^c.int,
	desired_channels: c.int,
) -> [^]byte {
	p := stbi.load_from_memory(buffer, len, x, y, channels_in_file, desired_channels)
	if p != nil {
		channels := desired_channels if desired_channels != 0 else channels_in_file^
		memtrack.track(&SITE, p, int(x^) * int(y^) * int(channels))
	}
	return p
}

// load_gif_from_memory is stbi.load_gif_from_memory. The delays are counted
// as well, and freed with image_free like the pixels.
load_gif_from_memory :: proc(
	buffer: [^]byte,
	len: c.int,
	delays: ^[^]c.int,
	x, y, z, comp: ^c.int,
	req_comp: c.int,
) -> [^]byte {
	p := stbi.load_gif_from_memory(buffer, len, delays, x, y, z, comp, req_comp)
	if p != nil {
		channels := req_comp if req_comp != 0 else comp^
		memtrack.track(&SITE, p, int(x^) * int(y^) * int(z^) * int(channels))
		memtrack.track(&SITE, delays^, int(z^) * size_of(c.int))
	}
	return p
}

// image_free is stbi.image_free.
image_free :: proc(p: rawptr) {
	memtrack.untrack(p)
	stbi.image_free(p)
}

info_from_memory :: stbi.info_from_memory
failure_reason :: stbi.failure_reason
