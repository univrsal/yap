#+build wasi
/*
The C declarations for a web build: the same as rnn_foreign.odin, generated from
it by web/gen_foreign.py. On wasm Odin names a named foreign import's
procs after the import ("system:c..name"), which no C object defines;
the unnamed form, `foreign _`, keeps the plain C names that emscripten
links against.
*/
package rnn

@(default_calling_convention = "c", link_prefix = "yap_rnnoise_")
foreign _ {
	// Must run once before any denoiser is used (Denoiser does this).
	global_init :: proc() ---
	create :: proc(model: rawptr = nil) -> ^State ---
	destroy :: proc(st: ^State) ---
	// FRAME_SIZE samples in 16-bit range (-32768..32767). Returns the
	// probability (0..1) that the frame contains voice.
	process_frame :: proc(st: ^State, output: [^]f32, input: [^]f32) -> f32 ---
}
