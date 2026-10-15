// Bindings for yap_audio.h, a small C API over a trimmed-down miniaudio
// (v0.11.25). yap_audio.c compiles it with only device I/O and the backends
// we use. Build the library with build.sh / build.bat at the repo root.
package miniaudio

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_audio.lib"
} else {
	@(private)
	LIB :: "libyap_audio.a"
}

// A web build doesn't link a library from here. Emscripten compiles
// yap_audio.c itself (see web/build.sh).
when ODIN_OS != .WASI {
	when !#exists(LIB) {
		#panic(
			"src/client/audio/miniaudio/" +
			LIB +
			" is missing; build it with build.sh (or build.bat on Windows)",
		)
	}
}


NAME_SIZE :: 256
ID_SIZE :: 512

Context :: struct {}
Stream :: struct {}

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

// Runs on miniaudio's audio thread once per period. For capture, `samples`
// holds `frame_count` recorded frames. For playback, fill it (it starts out
// zeroed). Samples are interleaved f32. Must not block.
Callback :: #type proc "c" (user: rawptr, samples: [^]f32, frame_count: c.uint)
