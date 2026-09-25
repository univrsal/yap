#+build !wasi
package miniaudio

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib {LIB}
} else when ODIN_OS == .Darwin {
	foreign import lib {LIB, "system:CoreFoundation.framework", "system:CoreAudio.framework", "system:AudioToolbox.framework"}
} else when ODIN_OS == .Linux {
	// Audio backends are loaded at runtime (dlopen); only libc bits are linked.
	foreign import lib {LIB, "system:dl", "system:pthread", "system:m"}
} else {
	// Likewise, but BSDs fold dlopen/dlsym into libc.
	foreign import lib {LIB, "system:pthread", "system:m"}
}

@(default_calling_convention = "c", link_prefix = "yap_audio_")
foreign lib {
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
