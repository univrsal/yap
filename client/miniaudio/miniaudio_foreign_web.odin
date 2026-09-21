#+build wasi
/*
The C declarations for a web build: the same as miniaudio_foreign.odin, generated from
it by web/gen_foreign.py. On wasm Odin names a named foreign import's
procs after the import ("system:c..name"), which no C object defines;
the unnamed form, `foreign _`, keeps the plain C names that emscripten
links against.
*/
package miniaudio

import "core:c"

@(default_calling_convention = "c", link_prefix = "yap_audio_")
foreign _ {
	create :: proc(result: ^Result) -> ^Context ---
	destroy :: proc(a: ^Context) ---
	backend_name :: proc(a: ^Context) -> cstring ---
	result_string :: proc(result: Result) -> cstring ---

	refresh :: proc(a: ^Context) -> Result ---
	device_count :: proc(a: ^Context, dir: Direction) -> c.int ---
	device_info :: proc(a: ^Context, dir: Direction, index: c.int, name: ^[NAME_SIZE]u8, is_default: ^c.int, id: ^Device_Id) -> Result ---

	stream_open :: proc(a: ^Context, dir: Direction, id: ^Device_Id, sample_rate, channels, period_ms: c.uint, callback: Callback, user: rawptr, result: ^Result) -> ^Stream ---
	stream_start :: proc(s: ^Stream) -> Result ---
	stream_stop :: proc(s: ^Stream) -> Result ---
	stream_close :: proc(s: ^Stream) ---
	// What the stream delivers/expects: as asked, or the native count if 0 was asked.
	stream_channels :: proc(s: ^Stream) -> c.uint ---
	stream_device_name :: proc(s: ^Stream, name: ^[NAME_SIZE]u8) ---
}
