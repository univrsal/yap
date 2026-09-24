#+build wasi
/*
The C declarations for a web build: the same as opus_foreign.odin, generated from
it by web/gen_foreign.py. On wasm Odin names a named foreign import's
procs after the import ("system:c..name"), which no C object defines;
the unnamed form, `foreign _`, keeps the plain C names that emscripten
links against.
*/
package opus

import "core:c"

@(default_calling_convention = "c", link_prefix = "opus_")
foreign _ {
	get_version_string :: proc() -> cstring ---
	strerror :: proc(error: Error) -> cstring ---

	encoder_get_size :: proc(channels: c.int) -> c.int ---
	encoder_create :: proc(Fs: i32, channels: c.int, application: Application, error: ^Error) -> ^Encoder ---
	encoder_init :: proc(st: ^Encoder, Fs: i32, channels: c.int, application: Application) -> Error ---
	encoder_destroy :: proc(st: ^Encoder) ---
	encoder_ctl :: proc(st: ^Encoder, request: Request, #c_vararg args: ..any) -> Error ---

	// frame_size is per channel and must be 2.5, 5, 10, 20, 40, 60, 80, 100
	// or 120 ms at the encoder's rate. Returns the packet length in bytes,
	// or a negative Error.
	encode :: proc(st: ^Encoder, pcm: [^]i16, frame_size: c.int, data: [^]u8, max_data_bytes: i32) -> i32 ---
	encode_float :: proc(st: ^Encoder, pcm: [^]f32, frame_size: c.int, data: [^]u8, max_data_bytes: i32) -> i32 ---

	decoder_get_size :: proc(channels: c.int) -> c.int ---
	decoder_create :: proc(Fs: i32, channels: c.int, error: ^Error) -> ^Decoder ---
	decoder_init :: proc(st: ^Decoder, Fs: i32, channels: c.int) -> Error ---
	decoder_destroy :: proc(st: ^Decoder) ---
	decoder_ctl :: proc(st: ^Decoder, request: Request, #c_vararg args: ..any) -> Error ---

	// data = nil (len 0) asks for packet loss concealment. decode_fec = 1
	// recovers the *previous* frame from this packet's in-band FEC.
	// Returns the number of samples per channel decoded, or a negative Error.
	decode :: proc(st: ^Decoder, data: [^]u8, len: i32, pcm: [^]i16, frame_size: c.int, decode_fec: c.int) -> c.int ---
	decode_float :: proc(st: ^Decoder, data: [^]u8, len: i32, pcm: [^]f32, frame_size: c.int, decode_fec: c.int) -> c.int ---
	decoder_get_nb_samples :: proc(dec: ^Decoder, packet: [^]u8, len: i32) -> c.int ---

	packet_get_bandwidth :: proc(data: [^]u8) -> c.int ---
	packet_get_samples_per_frame :: proc(data: [^]u8, Fs: i32) -> c.int ---
	packet_get_nb_channels :: proc(data: [^]u8) -> c.int ---
	packet_get_nb_frames :: proc(packet: [^]u8, len: i32) -> c.int ---
	packet_get_nb_samples :: proc(packet: [^]u8, len: i32, Fs: i32) -> c.int ---
	packet_has_lbrr :: proc(packet: [^]u8, len: i32) -> c.int ---
}
