/*
Per-application audio capture (see yap_aac.c and tinyaac.h, public
domain or MIT). Build the library with build.sh / build.bat at the repo
root.

List the applications playing audio, pick one, and its audio comes back
through a callback, as interleaved float32 at whatever rate and channel
count the application plays at. The callbacks run on a thread of
tinyaac's own, one at a time; capture_stop waits for the last one.

It's PipeWire on Linux (loaded at runtime, so init just fails without
it), WASAPI process loopback on Windows 10 build 19041 and later, and a
Core Audio process tap on macOS 14.2 and later. Elsewhere init fails.
*/
package aac

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_aac.lib"
} else {
	@(private)
	LIB :: "libyap_aac.a"
}

when !#exists(LIB) {
	#panic(
		"src/client/audio/aac/" +
		LIB +
		" is missing; build it with build.sh (or build.bat on Windows)",
	)
}

when ODIN_OS == .Windows {
	// uuid.lib for IID_IUnknown; the audio GUIDs are in yap_aac.c.
	foreign import lib {LIB, "system:ole32.lib", "system:user32.lib", "system:uuid.lib"}
} else when ODIN_OS == .Darwin {
	// AppKit for the applications' names (NSRunningApplication).
	foreign import lib {LIB, "system:Foundation.framework", "system:AppKit.framework", "system:CoreAudio.framework"}
} else when ODIN_OS == .Linux {
	// libpipewire-0.3 is dlopen'd at runtime (yap_aac.c) rather than
	// linked, so yap-client still starts without PipeWire.
	foreign import lib {LIB, "system:dl"}
} else {
	foreign import lib {LIB}
}

App_List :: struct {}
Capture :: struct {}

Status :: enum i32 {
	Ok                   = 0,
	Invalid_Argument     = -1,
	Invalid_State        = -2,
	Out_Of_Memory        = -3,
	Platform_Unavailable = -4,
	Permission_Denied    = -5,
	Not_Found            = -6,
	Backend              = -7,
	Unsupported_Format   = -8,
}

Event :: enum i32 {
	Started,
	Stopped,
	Target_Ended, // the application went away
	Backend_Error,
}

App_Info :: struct {
	// Owned by the list, and valid until it's destroyed.
	display_name: cstring,
	identifier:   cstring,
	process_id:   u32, // 0 where the backend doesn't say
}

Audio_Frame :: struct {
	// Interleaved, -1..1; only valid during the callback.
	samples:      [^]f32,
	frame_count:  uint,
	channels:     u32,
	sample_rate:  u32,
	timestamp_ns: u64,
}

Audio_Proc :: #type proc "c" (frame: ^Audio_Frame, user_data: rawptr)
Event_Proc :: #type proc "c" (event: Event, status: Status, message: cstring, user_data: rawptr)

@(default_calling_convention = "c")
foreign lib {
	// tinyaac_init, once libpipewire is loaded on Linux. Reference
	// counted: pair each success with shutdown.
	@(link_name = "yap_aac_init")
	init :: proc() -> Status ---
}

@(default_calling_convention = "c", link_prefix = "tinyaac_")
foreign lib {
	shutdown :: proc() ---
	// Why the last call failed, in words; never nil.
	last_error :: proc() -> cstring ---

	// A snapshot of the applications playing audio right now (on Windows,
	// every application with a window).
	app_list_create :: proc(out_list: ^^App_List) -> Status ---
	app_list_count :: proc(list: ^App_List) -> uint ---
	app_list_get :: proc(list: ^App_List, index: uint) -> ^App_Info ---
	app_list_destroy :: proc(list: ^App_List) ---

	// The capture keeps what it needs of the list, which may go after.
	capture_create :: proc(list: ^App_List, index: uint, out_capture: ^^Capture) -> Status ---
	capture_set_callbacks :: proc(capture: ^Capture, on_audio: Audio_Proc, on_event: Event_Proc, user_data: rawptr) -> Status ---
	capture_start :: proc(capture: ^Capture) -> Status ---
	// Returns once no callback is running any more.
	capture_stop :: proc(capture: ^Capture) -> Status ---
	capture_destroy :: proc(capture: ^Capture) ---
}
