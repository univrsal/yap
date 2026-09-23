/*
Bindings for libopus (https://opus-codec.org), statically linked from the
prebuilt libraries in this directory:

	libopus.a  Linux x86-64
	opus.lib   Windows x86-64 (MSVC)

Only the single-stream encoder/decoder API is bound, which is all a voice
chat needs; the multistream, projection, repacketizer and DRED APIs are
left out. Constants and signatures follow opus.h / opus_defines.h 1.6.

The *_ctl procs are C varargs. The typed helpers (encoder_set, encoder_get,
...) are safer: every request takes or returns an opus_int32.
*/
package opus

import "core:c"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "opus.lib"
} else when ODIN_OS == .Linux {
	@(private)
	LIB :: "libopus.a"
} else when ODIN_OS == .WASI {
	// A web build links no library from here: web/build.sh builds libopus
	// for wasm and hands it to emscripten, and opus_foreign_web.odin
	// declares what it provides.
	@(private)
	LIB :: ""
} else {
	#panic("no libopus build for this platform in client/opus")
}

when ODIN_OS == .Windows || ODIN_OS == .Linux {
	when !#exists(LIB) {
		#panic("client/opus/" + LIB + " is missing")
	}
}


Encoder :: struct {}
Decoder :: struct {}

// Return codes. Procs that return a count use negative values for these.
Error :: enum c.int {
	OK               = 0,
	Bad_Arg          = -1,
	Buffer_Too_Small = -2,
	Internal_Error   = -3,
	Invalid_Packet   = -4,
	Unimplemented    = -5,
	Invalid_State    = -6,
	Alloc_Fail       = -7,
}

Application :: enum c.int {
	VOIP                = 2048, // speech: best quality at low bitrates
	Audio               = 2049, // music and mixed content
	Restricted_Lowdelay = 2051, // lowest latency, CELT only
	Restricted_SILK     = 2052,
	Restricted_CELT     = 2053,
}

// Values for several requests (bitrate, bandwidth, signal, ...).
AUTO :: -1000
BITRATE_MAX :: -1

SIGNAL_VOICE :: 3001
SIGNAL_MUSIC :: 3002

BANDWIDTH_NARROWBAND :: 1101 //  4 kHz
BANDWIDTH_MEDIUMBAND :: 1102 //  6 kHz
BANDWIDTH_WIDEBAND :: 1103 //  8 kHz
BANDWIDTH_SUPERWIDEBAND :: 1104 // 12 kHz
BANDWIDTH_FULLBAND :: 1105 // 20 kHz

FRAMESIZE_ARG :: 5000
FRAMESIZE_2_5_MS :: 5001
FRAMESIZE_5_MS :: 5002
FRAMESIZE_10_MS :: 5003
FRAMESIZE_20_MS :: 5004
FRAMESIZE_40_MS :: 5005
FRAMESIZE_60_MS :: 5006
FRAMESIZE_80_MS :: 5007
FRAMESIZE_100_MS :: 5008
FRAMESIZE_120_MS :: 5009

// The largest packet Opus produces for one frame, per its documentation's
// recommendation for max_data_bytes.
MAX_PACKET_SIZE :: 1275
// The largest frame: 120 ms at 48 kHz, per channel.
MAX_FRAME_SAMPLES :: 5760

// ctl requests. SET requests take an i32; GET requests take a ^i32
// (GET_FINAL_RANGE a ^u32).
Request :: enum c.int {
	Set_Application              = 4000,
	Get_Application              = 4001,
	Set_Bitrate                  = 4002,
	Get_Bitrate                  = 4003,
	Set_Max_Bandwidth            = 4004,
	Get_Max_Bandwidth            = 4005,
	Set_VBR                      = 4006,
	Get_VBR                      = 4007,
	Set_Bandwidth                = 4008,
	Get_Bandwidth                = 4009,
	Set_Complexity               = 4010,
	Get_Complexity               = 4011,
	Set_Inband_FEC               = 4012,
	Get_Inband_FEC               = 4013,
	Set_Packet_Loss_Perc         = 4014,
	Get_Packet_Loss_Perc         = 4015,
	Set_DTX                      = 4016,
	Get_DTX                      = 4017,
	Set_VBR_Constraint           = 4020,
	Get_VBR_Constraint           = 4021,
	Set_Force_Channels           = 4022,
	Get_Force_Channels           = 4023,
	Set_Signal                   = 4024,
	Get_Signal                   = 4025,
	Get_Lookahead                = 4027,
	Reset_State                  = 4028, // takes no argument
	Get_Sample_Rate              = 4029,
	Get_Final_Range              = 4031,
	Get_Pitch                    = 4033,
	Set_Gain                     = 4034,
	Set_LSB_Depth                = 4036,
	Get_LSB_Depth                = 4037,
	Get_Last_Packet_Duration     = 4039,
	Set_Expert_Frame_Duration    = 4040,
	Get_Expert_Frame_Duration    = 4041,
	Set_Prediction_Disabled      = 4042,
	Get_Prediction_Disabled      = 4043,
	Get_Gain                     = 4045,
	Set_Phase_Inversion_Disabled = 4046,
	Get_Phase_Inversion_Disabled = 4047,
	Get_In_DTX                   = 4049,
	Set_DRED_Duration            = 4050,
	Get_DRED_Duration            = 4051,
}


// Typed ctl helpers.

encoder_set :: proc(st: ^Encoder, request: Request, value: i32) -> Error {
	return encoder_ctl(st, request, value)
}

encoder_get :: proc(st: ^Encoder, request: Request) -> (value: i32, err: Error) {
	err = encoder_ctl(st, request, &value)
	return
}

decoder_set :: proc(st: ^Decoder, request: Request, value: i32) -> Error {
	return decoder_ctl(st, request, value)
}

decoder_get :: proc(st: ^Decoder, request: Request) -> (value: i32, err: Error) {
	err = decoder_ctl(st, request, &value)
	return
}

encoder_reset :: proc(st: ^Encoder) -> Error {
	return encoder_ctl(st, .Reset_State)
}

decoder_reset :: proc(st: ^Decoder) -> Error {
	return decoder_ctl(st, .Reset_State)
}

// result_error turns a negative count returned by encode/decode into an Error.
result_error :: proc(n: $T) -> Error {
	return n < 0 ? Error(n) : .OK
}
