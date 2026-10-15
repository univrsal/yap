#+build !wasi
package miniaudio

import "core:c"

// Decoding sound files (WAV, FLAC, MP3), on a desktop only: a browser decodes
// them itself. Kept apart from miniaudio_foreign.odin, which
// web/gen_foreign.py copies for the web build.

when ODIN_OS == .Windows {
	foreign import decode_lib {LIB}
} else {
	foreign import decode_lib {LIB, "system:m"}
}

@(default_calling_convention = "c", link_prefix = "yap_audio_")
foreign decode_lib {
	// The samples are interleaved f32 at `sample_rate` with `channels`.
	// Free them with decoded_free.
	decode :: proc(data: rawptr, size: c.size_t, sample_rate, channels: c.uint, samples: ^[^]f32, frame_count: ^c.ulonglong) -> Result ---
	decoded_free :: proc(samples: [^]f32) ---
}
