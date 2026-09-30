#+build !wasi
package rnn

when ODIN_OS == .Windows {
	foreign import lib {LIB}
} else {
	foreign import lib {LIB, "system:m"}
}

@(default_calling_convention = "c", link_prefix = "yap_rnnoise_")
foreign lib {
	// Must run once before any denoiser is used (Denoiser does this).
	global_init :: proc() ---
	create :: proc(model: rawptr = nil) -> ^State ---
	destroy :: proc(st: ^State) ---
	// FRAME_SIZE samples in 16-bit range (-32768..32767). Returns the
	// probability (0..1) that the frame contains voice.
	process_frame :: proc(st: ^State, output: [^]f32, input: [^]f32) -> f32 ---
}
