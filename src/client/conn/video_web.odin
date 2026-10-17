#+build wasi
package conn

import log "common:wlog"
import "core:sync"

import "client:audio"
import "client:render"
import "common:proto"

// Screen sharing in the browser: the page captures, encodes and decodes
// (Module.yapVideo in web/video.js, reached through web/shell.c), and the client
// carries the encoded frames (video.odin).

@(private = "file", default_calling_convention = "c")
foreign _ {
	// 1 while the capture is running.
	yap_video_live :: proc() -> i32 ---
	// The size of the oldest encoded frame waiting, or -1 if there is none.
	yap_video_next_size :: proc() -> i32 ---
	// Copies the oldest encoded frame into buf and returns its size, or -1 if
	// there is none (or it does not fit).
	yap_video_pull :: proc(buf: [^]u8, buf_size: i32, ts: ^u32, key: ^i32) -> i32 ---
	// 1 while the share carries audio too.
	yap_video_audio_live :: proc() -> i32 ---
	// Copies up to `max` samples of the shared audio (interleaved stereo, 48
	// kHz) into buf and returns how many.
	yap_video_audio_pull :: proc(buf: [^]f32, max: i32) -> i32 ---
	// Makes the next frame a keyframe.
	yap_video_request_key :: proc() ---
	// Hands a frame from `sharer` to the decoder.
	yap_video_show :: proc(sharer: u32, data: [^]u8, size: i32, ts: u32, key: i32, codec: i32) ---
	// Drops the decoder and clears the picture.
	yap_video_end :: proc() ---
	// Returns 1 once after the decoder has failed.
	yap_video_take_error :: proc() -> i32 ---
	yap_video_can_share :: proc() -> i32 ---
	yap_video_can_watch :: proc() -> i32 ---
	// What the decoder accepts, as bits (1 << codec). It grows as the browser
	// answers.
	yap_video_decodable :: proc() -> i32 ---
	yap_video_share_start :: proc() ---
	yap_video_share_stop :: proc() ---
	yap_video_share_state :: proc() -> i32 ---
	yap_video_upload :: proc(texture: u32, width, height: ^i32) -> i32 ---
	yap_video_set_fullscreen :: proc(on: i32) ---
	yap_video_is_fullscreen :: proc() -> i32 ---
}

video_capture_live :: proc() -> bool {
	return yap_video_live() != 0
}

// video_capture_pull returns the next encoded frame, which the caller then
// owns.
video_capture_pull :: proc(
) -> (
	data: []u8,
	ts: u32,
	key: bool,
	codec: proto.Video_Codec,
	ok: bool,
) {
	size := yap_video_next_size()
	if size <= 0 {
		return
	}
	data = make([]u8, size)
	key_flag: i32
	if yap_video_pull(raw_data(data), size, &ts, &key_flag) != size {
		delete(data)
		return nil, 0, false, .H264, false
	}
	return data, ts, key_flag != 0, .H264, true
}

// video_capture_audio moves the audio the browser shares with the picture (a
// tab's, or the system's with a screen) into the voice's app ring while we are
// sharing here. It is then sent mixed into our voice, like a native client's
// shared application (app_mix in audio/voice.odin). Whatever comes while we
// aren't is dropped.
video_capture_audio :: proc(v: ^audio.Voice, sharing: bool) {
	live := sharing && yap_video_audio_live() != 0
	if live != sync.atomic_load(&v.app_input) {
		sync.atomic_store(&v.app_input, live)
		log.infof("screen sharing: audio %s", "on" if live else "off")
	}
	buf: [2048]f32
	for {
		n := int(yap_video_audio_pull(raw_data(buf[:]), i32(len(buf))))
		if n <= 0 {
			break
		}
		if live {
			audio.ring_write(&v.app, buf[:n])
			sync.atomic_add(&v.app_received, u32(n / audio.CHANNELS))
		}
	}
}

video_capture_request_key :: proc() {
	yap_video_request_key()
}

video_show_frame :: proc(sharer: proto.User_Num, frame: proto.Video_Frame) {
	yap_video_show(
		u32(sharer),
		raw_data(frame.data),
		i32(len(frame.data)),
		frame.ts,
		1 if frame.key else 0,
		i32(frame.codec),
	)
}

video_show_end :: proc() {
	yap_video_end()
	web_picture.size = {} // do not keep the last picture's size
}

// video_show_failed says, once, that the decoder gave up on what it was given.
// It needs a keyframe to start again.
video_show_failed :: proc() -> bool {
	return yap_video_take_error() != 0
}

// For the UI. Starting a share opens the browser's picker, which the browser
// only allows shortly after the user clicked something, so it belongs in a
// button handler.

// What the page's capture is doing (web/video.js).
Share_State :: enum i32 {
	Off      = 0,
	Starting = 1, // the browser's picker is open
	Live     = 2,
	Failed   = 3, // it could not start, or stopped with an error
}

video_can_share :: proc() -> bool {
	return yap_video_can_share() != 0
}

video_can_watch :: proc() -> bool {
	return yap_video_can_watch() != 0
}

video_decodable :: proc() -> proto.Video_Codecs {
	return transmute(proto.Video_Codecs)u8(yap_video_decodable())
}

// The page always encodes H.264, which every viewer can decode.
video_share_codecs :: proc(codecs: proto.Video_Codecs) {}

video_share_start :: proc() {
	yap_video_share_start()
}

video_share_stop :: proc() {
	yap_video_share_stop()
}

video_share_state :: proc() -> Share_State {
	return Share_State(yap_video_share_state())
}

// The browser asks what to share in its own picker.
VIDEO_PICKER :: false

// The browser asks in its own picker, so nothing needs to be allowed first.
video_capture_allowed :: proc() -> bool {
	return true
}

video_allow_capture :: proc() {}

// What the page encodes at is not reported; video.odin paces for it.
video_share_kbit :: proc() -> int {
	return 0
}

// The browser's share does not follow its viewers' reports: the page's encoder
// keeps to its own bitrate.
video_share_max_kbit :: proc() -> int {
	return 0
}

video_share_adapt :: proc(kbit: int) {}

Video_Source_Kind :: enum {
	Monitor,
	Window,
}

Video_Source :: struct {
	kind:          Video_Source_Kind,
	id:            u64,
	name:          string,
	app:           string,
	width, height: int,
	primary:       bool,
}

video_sources :: proc(allocator := context.temp_allocator) -> []Video_Source {
	return nil
}

video_share_source :: proc(src: Video_Source, config: Share_Config) {}

// A page has no library to look for.
video_library_dir :: proc(allocator := context.temp_allocator) -> string {
	return ""
}

// The browser's picker is ours to open, not the system's.
video_system_picker :: proc() -> bool {
	return false
}

// The browser chooses its encoder and does not say which.
Video_Encoder :: struct {
	name:  string,
	label: string,
	works: bool,
}

video_encoders :: proc(allocator := context.temp_allocator) -> []Video_Encoder {
	return nil
}

// The page shows the picture without the library's counts.
video_picture_info :: proc() -> (frames: u64, hardware: bool) {
	return 0, false
}

// The page draws each new picture as it arrives, so no waking is needed.
video_set_wake :: proc(wake: proc "c" ()) {}

// The browser's console says why it failed.
video_share_error :: proc() -> string {
	return ""
}

// The texture the page draws frames into, and the size of the picture in it.
@(private = "file")
web_picture: struct {
	texture: render.Gpu_Texture,
	size:    [2]int,
}

// video_picture is the newest frame of what we are watching, as a texture of
// the renderer's. The page puts each new frame into it (an OpenGL texture name,
// as the page knows it, render/gpu_gl.odin).
video_picture :: proc(
	g: ^render.Gpu,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	p := &web_picture
	if p.texture == 0 {
		p.texture = render.gpu_texture_make(g, .Rgba, 0, 0, nil)
	}
	w, h: i32
	if yap_video_upload(u32(p.texture), &w, &h) != 0 {
		p.size = {int(w), int(h)}
	}
	if p.size.x <= 0 || p.size.y <= 0 {
		return
	}
	return p.texture, p.size.x, p.size.y, true
}

// video_forget_gpu forgets the texture when its device goes away.
video_forget_gpu :: proc(g: ^render.Gpu) {
	web_picture = {}
}

// The whole page goes fullscreen, to show the picture (ui_video.odin).
video_set_fullscreen :: proc(on: bool) {
	yap_video_set_fullscreen(1 if on else 0)
}

video_is_fullscreen :: proc() -> bool {
	return yap_video_is_fullscreen() != 0
}
