/*
Bindings for yap_audio.h: a small C API over a trimmed-down miniaudio
(v0.11.25, compiled by yap_audio.c with only device I/O and the backends
we use). Build the library with build.sh / build.bat at the repo root.
*/
package miniaudio

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_audio.lib"
} else {
	@(private)
	LIB :: "libyap_audio.a"
}

when !#exists(LIB) {
	#panic("client/miniaudio/" + LIB + " is missing; build it with build.sh (or build.bat on Windows)")
}

when ODIN_OS == .Windows {
	foreign import lib { LIB }
} else when ODIN_OS == .Darwin {
	foreign import lib { LIB, "system:CoreFoundation.framework", "system:CoreAudio.framework", "system:AudioToolbox.framework" }
} else {
	// Audio backends are loaded at runtime (dlopen); only libc bits are linked.
	foreign import lib { LIB, "system:dl", "system:pthread", "system:m" }
}

NAME_SIZE :: 256
ID_SIZE   :: 512

Context :: struct {}
Stream  :: struct {}

Device_Id :: struct {
	bytes: [ID_SIZE]u8,
}

Direction :: enum c.int {
	Playback = 0,
	Capture  = 1,
}

// miniaudio's ma_result: 0 is success, negative values are errors.
Result :: distinct c.int
SUCCESS :: Result(0)

// Runs on miniaudio's audio thread, once per period. For capture, `samples`
// holds `frame_count` recorded frames; for playback, fill it (it starts
// zeroed). Interleaved f32. Must not block.
Callback :: #type proc "c" (user: rawptr, samples: [^]f32, frame_count: c.uint)

@(default_calling_convention = "c", link_prefix = "yap_audio_")
foreign lib {
	create           :: proc(result: ^Result) -> ^Context ---
	destroy          :: proc(a: ^Context) ---
	backend_name     :: proc(a: ^Context) -> cstring ---
	result_string    :: proc(result: Result) -> cstring ---

	refresh          :: proc(a: ^Context) -> Result ---
	device_count     :: proc(a: ^Context, dir: Direction) -> c.int ---
	device_info      :: proc(a: ^Context, dir: Direction, index: c.int, name: ^[NAME_SIZE]u8, is_default: ^c.int, id: ^Device_Id) -> Result ---

	stream_open      :: proc(a: ^Context, dir: Direction, id: ^Device_Id, sample_rate, channels, period_ms: c.uint, callback: Callback, user: rawptr, result: ^Result) -> ^Stream ---
	stream_start     :: proc(s: ^Stream) -> Result ---
	stream_stop      :: proc(s: ^Stream) -> Result ---
	stream_close     :: proc(s: ^Stream) ---
	stream_device_name :: proc(s: ^Stream, name: ^[NAME_SIZE]u8) ---
}
