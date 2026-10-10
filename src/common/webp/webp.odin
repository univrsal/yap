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
	libwebpdemux.a / libwebpdemux.lib   its animation decoder
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
	DEMUX :: "libwebpdemux.lib"
	@(private)
	SHARPYUV :: "libsharpyuv.lib"
} else {
	@(private)
	SHIM :: "libyap_webp.a"
	@(private)
	WEBP :: "libwebp.a"
	@(private)
	DEMUX :: "libwebpdemux.a"
	@(private)
	SHARPYUV :: "libsharpyuv.a"
}

when !#exists(SHIM) || !#exists(WEBP) || !#exists(DEMUX) || !#exists(SHARPYUV) {
	#panic(
		"src/common/webp/" +
		SHIM +
		", " +
		WEBP +
		", " +
		DEMUX +
		" or " +
		SHARPYUV +
		" is missing (build them with build.sh or scripts/build-webp.sh, or build.bat on Windows)",
	)
}

// The shim first: it's what needs libwebpdemux, which needs libwebp,
// which needs libsharpyuv.
foreign import lib {SHIM, DEMUX, WEBP, SHARPYUV}

@(default_calling_convention = "c", link_prefix = "yap_webp_", private)
foreign lib {
	info :: proc(data: [^]u8, size: c.size_t, width, height: ^c.int) -> c.int ---
	decode_rgba :: proc(data: [^]u8, size: c.size_t, out: [^]u8, out_size: c.size_t, stride: c.int) -> c.int ---
	@(link_name = "yap_webp_encode")
	encode_c :: proc(pixels: [^]u8, width, height, alpha: c.int, quality: c.float, method: c.int, out: ^[^]u8) -> c.size_t ---
	@(link_name = "yap_webp_free")
	release :: proc(p: rawptr) ---
	@(link_name = "yap_webp_is_animation")
	animation_kind :: proc(data: [^]u8, size: c.size_t) -> c.int ---
	@(link_name = "yap_webp_anim_open")
	anim_open_c :: proc(data: [^]u8, size: c.size_t, width, height, frames, loops: ^c.int) -> Anim ---
	@(link_name = "yap_webp_anim_next")
	anim_next_c :: proc(dec: Anim, pixels: ^[^]u8, timestamp: ^c.int) -> c.int ---
	@(link_name = "yap_webp_anim_reset")
	anim_reset_c :: proc(dec: Anim) ---
	@(link_name = "yap_webp_anim_close")
	anim_close_c :: proc(dec: Anim) ---
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

// is_animation is whether `data` is an animated WebP: false for a still
// one, and for anything that isn't a WebP.
is_animation :: proc(data: []u8) -> bool {
	return len(data) > 0 && animation_kind(raw_data(data), len(data)) == 1
}

/*
An animation being decoded a frame at a time: anim_open, anim_next until
it says there are no more, anim_reset to go round again, and anim_close.
The bytes it was opened with must stay as they are until it's closed. A
still picture opens too, as one frame.
*/
Anim :: distinct rawptr

Anim_Info :: struct {
	width, height: int, // the canvas, which every frame covers
	frames:        int,
	loops:         int, // how often it plays; 0 is for ever
}

anim_open :: proc(data: []u8) -> (dec: Anim, info: Anim_Info, ok: bool) {
	if len(data) == 0 {
		return
	}
	w, h, frames, loops: c.int
	dec = anim_open_c(raw_data(data), len(data), &w, &h, &frames, &loops)
	if dec == nil {
		return
	}
	return dec, {int(w), int(h), int(frames), int(loops)}, true
}

Anim_Next :: enum {
	Frame, // `pixels` is the next frame
	End, // there's no frame after the last
	Broken, // the data is
}

/*
anim_next decodes the next frame. `pixels` is the whole canvas, RGBA,
the decoder's own and good until the next call, and `ends` is when the
frame ends, in milliseconds from the start of the animation.
*/
anim_next :: proc(dec: Anim, info: Anim_Info) -> (pixels: []u8, ends: int, next: Anim_Next) {
	p: [^]u8
	ts: c.int
	switch anim_next_c(dec, &p, &ts) {
	case 1:
		return p[:info.width * info.height * 4], int(ts), .Frame
	case 0:
		return nil, 0, .End
	}
	return nil, 0, .Broken
}

anim_reset :: proc(dec: Anim) {
	anim_reset_c(dec)
}

anim_close :: proc(dec: Anim) {
	if dec != nil {
		anim_close_c(dec)
	}
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
	return encode_pixels(rgb, width, height, false, quality, method, allocator)
}

// encode_rgba is encode for `rgba` (rows of width * 4 bytes): the colour
// lossily at `quality`, the alpha as it is.
encode_rgba :: proc(
	rgba: []u8,
	width, height: int,
	quality: f32,
	method := 4,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	return encode_pixels(rgba, width, height, true, quality, method, allocator)
}

@(private = "file")
encode_pixels :: proc(
	pixels: []u8,
	width, height: int,
	alpha: bool,
	quality: f32,
	method: int,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	if width <= 0 || height <= 0 || len(pixels) < width * height * (4 if alpha else 3) {
		return nil, false
	}
	out: [^]u8
	n := encode_c(
		raw_data(pixels),
		c.int(width),
		c.int(height),
		c.int(alpha),
		quality,
		c.int(method),
		&out,
	)
	if n == 0 {
		return nil, false
	}
	defer release(out)
	data = make([]u8, int(n), allocator)
	copy(data, out[:n])
	return data, true
}
