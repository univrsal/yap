#+build wasi
// The C declarations for a web build. They are the same as in
// rnn_foreign.odin and are generated from it by web/gen_foreign.py.
// On wasm, Odin names the procs of a named foreign import after the import
// ("system:c..name"), which no C object defines. The unnamed form,
// `foreign _`, keeps the plain C names that emscripten links against.
package rnn

@(default_calling_convention = "c", link_prefix = "yap_rnnoise_")
foreign _ {
	// Must be called once before any denoiser is used (Denoiser does this).
	global_init :: proc() ---
	create :: proc(model: rawptr = nil) -> ^State ---
	destroy :: proc(st: ^State) ---
	// Takes FRAME_SIZE samples in the 16-bit range (-32768..32767). Returns
	// the probability (0..1) that the frame contains voice.
	process_frame :: proc(st: ^State, output: [^]f32, input: [^]f32) -> f32 ---
}
