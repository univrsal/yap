#+build !wasi
/*
WebP pictures (https://developers.google.com/speed/webp): decoding them
and compressing pasted images to them. libwebp is statically linked from
libraries in this directory, none of them kept in the repo: build.sh
(build.bat on Windows) fetches the release named in scripts/webp.version
and builds it, for size but with its SIMD code, and compiles yap_webp.c,
which is what's bound here.

	libyap_webp.a / yap_webp.lib        yap_webp.c
	libwebp.a     / libwebp.lib         libwebp
	libsharpyuv.a / libsharpyuv.lib     what libwebp's encoder needs

A web build has none of this: the browser decodes pictures (web/decode.js)
and compresses pastes (web/paste.js).
*/
package webp

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	SHIM :: "yap_webp.lib"
	@(private)
	WEBP :: "libwebp.lib"
	@(private)
	SHARPYUV :: "libsharpyuv.lib"
} else {
	@(private)
	SHIM :: "libyap_webp.a"
	@(private)
	WEBP :: "libwebp.a"
	@(private)
	SHARPYUV :: "libsharpyuv.a"
}

when !#exists(SHIM) || !#exists(WEBP) || !#exists(SHARPYUV) {
	#panic(
		"src/client/webp/" +
		SHIM +
		", " +
		WEBP +
		" or " +
		SHARPYUV +
		" is missing (build them with build.sh, or build.bat on Windows)",
	)
}

// The shim first: it's what needs libwebp, which needs libsharpyuv.
foreign import lib {SHIM, WEBP, SHARPYUV}

@(default_calling_convention = "c", link_prefix = "yap_webp_", private)
foreign lib {
	info :: proc(data: [^]u8, size: c.size_t, width, height: ^c.int) -> c.int ---
	decode_rgba :: proc(data: [^]u8, size: c.size_t, out: [^]u8, out_size: c.size_t, stride: c.int) -> c.int ---
	encode_rgb :: proc(rgb: [^]u8, width, height: c.int, quality: c.float, method: c.int, out: ^[^]u8) -> c.size_t ---
	@(link_name = "yap_webp_free")
	release :: proc(p: rawptr) ---
}

// is_webp is whether `data` starts the way a WebP file does: a RIFF
// container of WEBP.
is_webp :: proc(data: []u8) -> bool {
	return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
}

// size is a WebP picture's width and height, from its header.
size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	w, h: c.int
	if len(data) == 0 || info(raw_data(data), len(data), &w, &h) == 0 {
		return 0, 0, false
	}
	return int(w), int(h), true
}

// decode_into decodes a WebP picture `width` pixels wide into `pixels`,
// as RGBA rows top to bottom. False for an animation or broken data.
decode_into :: proc(data: []u8, pixels: []u8, width: int) -> bool {
	if len(data) == 0 || len(pixels) == 0 {
		return false
	}
	return decode_rgba(raw_data(data), len(data), raw_data(pixels), len(pixels), c.int(width * 4)) != 0
}

/*
encode compresses `rgb` (rows of width * 3 bytes) lossily at `quality`
(0 to 100). `method` trades speed for size, from 0 (fastest) to 6
(smallest); 4 is libwebp's default.
*/
encode :: proc(
	rgb: []u8,
	width, height: int,
	quality: f32,
	method := 4,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	if width <= 0 || height <= 0 || len(rgb) < width * height * 3 {
		return nil, false
	}
	out: [^]u8
	n := encode_rgb(raw_data(rgb), c.int(width), c.int(height), quality, c.int(method), &out)
	if n == 0 {
		return nil, false
	}
	defer release(out)
	data = make([]u8, int(n), allocator)
	copy(data, out[:n])
	return data, true
}
