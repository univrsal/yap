#+build wasi
package video

import log "common:wlog"
import "core:strings"
import "core:sync"
import "core:time"

import "client:audio"
import "client:render"
import "common:proto"

// Screen sharing and the camera in the browser: the page captures, encodes and
// decodes (Module.yapVideo in web/video.js, reached through web/shell.c), and
// the client carries the encoded frames (video.odin). The page has a capture
// for the screen and one for the camera, and a decoder for each stream
// watched.

// A page's media link is a WebSocket through the server's relay: nothing on it
// is lost or reordered, only late, so what is watched is never asked for again
// (proto.Video_Window.reliable).
MEDIA_RELIABLE :: true

@(private = "file", default_calling_convention = "c")
foreign _ {
	// 1 while a stream's capture is running.
	yap_video_live :: proc(stream: i32) -> i32 ---
	// The size of a stream's oldest encoded frame waiting, or -1 if there is
	// none.
	yap_video_next_size :: proc(stream: i32) -> i32 ---
	// Copies a stream's oldest encoded frame into buf and returns its size, or
	// -1 if there is none (or it does not fit).
	yap_video_pull :: proc(stream: i32, buf: [^]u8, buf_size: i32, ts: ^u32, key: ^i32, codec: ^i32) -> i32 ---
	// 1 while the screen's share carries audio too.
	yap_video_audio_live :: proc() -> i32 ---
	// Copies up to `max` samples of the shared audio (interleaved stereo, 48
	// kHz) into buf and returns how many.
	yap_video_audio_pull :: proc(buf: [^]f32, max: i32) -> i32 ---
	// Makes a stream's next frame a keyframe.
	yap_video_request_key :: proc(stream: i32) ---
	// Hands a frame of `sharer`'s stream to its decoder.
	yap_video_show :: proc(sharer: u32, stream: i32, data: [^]u8, size: i32, ts: u32, key: i32, codec: i32) ---
	// Drops a stream's decoder and its picture.
	yap_video_end :: proc(sharer: u32, stream: i32) ---
	// Returns 1 once after a stream's decoder has failed.
	yap_video_take_error :: proc(sharer: u32, stream: i32) -> i32 ---
	yap_video_can_share :: proc() -> i32 ---
	yap_video_can_camera :: proc() -> i32 ---
	yap_video_can_watch :: proc() -> i32 ---
	// What the decoder accepts, as bits (1 << codec). It grows as the browser
	// answers.
	yap_video_decodable :: proc() -> i32 ---
	// The page's encoders, best first: how many (-1 while they are being
	// tried, which asking starts), and one's name, label and whether it works.
	yap_video_encoder_count :: proc() -> i32 ---
	yap_video_encoder_info :: proc(i: i32, name: [^]u8, name_size: i32, label: [^]u8, label_size: i32, works: ^i32) -> i32 ---
	// Opens the browser's picker, then shares at most max_width by max_height
	// (0: the screen's own size), `fps` frames a second, at `kbit`, with the
	// page's `encoder` ("" for the best that works).
	yap_video_share_start :: proc(fps, kbit, max_width, max_height: i32, encoder: cstring) ---
	// Turns on the camera `device` ("" for the browser's choice), as big as
	// max_width by max_height at most.
	yap_video_camera_start :: proc(fps, kbit, max_width, max_height: i32, device: cstring, encoder: cstring) ---
	// What a stream's viewers decode, as bits (1 << codec; 0 for any).
	yap_video_set_codecs :: proc(stream: i32, codecs: i32) ---
	// Why a stream failed, into buf; "" if only the browser's console says.
	yap_video_why :: proc(stream: i32, buf: [^]u8, buf_size: i32) ---
	// Has the camera go on at another size, frame rate or bitrate.
	yap_video_camera_configure :: proc(fps, kbit, max_width, max_height: i32) ---
	// Stops encoding the camera while nobody watches it, or goes on.
	yap_video_camera_pause :: proc(paused: i32) ---
	// The settings' cameras, as the browser last listed them.
	yap_video_cameras_refresh :: proc() ---
	yap_video_camera_count :: proc() -> i32 ---
	yap_video_camera_info :: proc(i: i32, id: [^]u8, id_size: i32, name: [^]u8, name_size: i32) -> i32 ---
	// The settings' preview while our camera is off (not sent).
	yap_video_camera_look :: proc(device: cstring, max_width, max_height: i32) ---
	yap_video_camera_look_stop :: proc() ---
	yap_video_camera_look_state :: proc() -> i32 ---
	// What a stream encodes at now, and the most it may (kbit/s, 0 while it
	// isn't live).
	yap_video_encoding_kbit :: proc(stream: i32) -> i32 ---
	yap_video_max_kbit :: proc(stream: i32) -> i32 ---
	yap_video_set_bitrate :: proc(stream: i32, kbit: i32) ---
	yap_video_stop :: proc(stream: i32) ---
	yap_video_state :: proc(stream: i32) -> i32 ---
	// Puts the newest frame of `sharer`'s stream (sharer 0: our camera's) into
	// `texture`; 0 if there was none.
	yap_video_upload :: proc(sharer: u32, stream: i32, texture: u32, width, height: ^i32) -> i32 ---
	yap_video_set_fullscreen :: proc(on: i32) ---
	yap_video_is_fullscreen :: proc() -> i32 ---
}

capture_live :: proc(stream: proto.Video_Stream) -> bool {
	return yap_video_live(i32(stream)) != 0
}

// capture_pull returns the next encoded frame of a stream, which the
// caller then owns.
capture_pull :: proc(
	stream: proto.Video_Stream,
) -> (
	data: []u8,
	ts: u32,
	key: bool,
	codec: proto.Video_Codec,
	ok: bool,
) {
	size := yap_video_next_size(i32(stream))
	if size <= 0 {
		return
	}
	data = make([]u8, size)
	key_flag, codec_num: i32
	if yap_video_pull(i32(stream), raw_data(data), size, &ts, &key_flag, &codec_num) != size {
		delete(data)
		return nil, 0, false, .H264, false
	}
	return data, ts, key_flag != 0, proto.Video_Codec(codec_num), true
}

// capture_audio moves the audio the browser shares with the picture (a
// tab's, or the system's with a screen) into the voice's app ring while we are
// sharing here. It is then sent mixed into our voice, like a native client's
// shared application (app_mix in audio/voice.odin). Whatever comes while we
// aren't is dropped.
capture_audio :: proc(v: ^audio.Voice, sharing: bool) {
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

capture_request_key :: proc(stream: proto.Video_Stream) {
	yap_video_request_key(i32(stream))
}

// The page's decoders are always there to take frames.
show_ready :: proc(key: Key) -> bool {
	return true
}

show_frame :: proc(key: Key, frame: proto.Video_Frame) {
	yap_video_show(
		u32(key.user),
		i32(key.stream),
		raw_data(frame.data),
		i32(len(frame.data)),
		frame.ts,
		1 if frame.key else 0,
		i32(frame.codec),
	)
}

show_end :: proc(key: Key) {
	yap_video_end(u32(key.user), i32(key.stream))
	// Do not keep the last picture's size.
	for &p in web_pictures {
		if p.key == key {
			p.size = {}
		}
	}
}

// show_failed says, once, that a stream's decoder gave up on what it was
// given. It needs a keyframe to start again.
show_failed :: proc(key: Key) -> bool {
	return yap_video_take_error(u32(key.user), i32(key.stream)) != 0
}

// For the UI. Starting a share opens the browser's picker, which the browser
// only allows shortly after the user clicked something, so it belongs in a
// button handler. The camera asks for permission the first time, likewise.

can_share :: proc() -> bool {
	return yap_video_can_share() != 0
}

can_watch :: proc() -> bool {
	return yap_video_can_watch() != 0
}

decodable :: proc() -> proto.Video_Codecs {
	return transmute(proto.Video_Codecs)u8(yap_video_decodable())
}

// What each stream's viewers decode, as the page was last told.
@(private = "file")
share_codecs: [proto.Video_Stream]proto.Video_Codecs

// share_codecs says what the share's viewers can decode (video.odin),
// which the page's best encoder keeps to.
share_codecs :: proc(stream: proto.Video_Stream, codecs: proto.Video_Codecs) {
	if share_codecs[stream] == codecs {
		return
	}
	share_codecs[stream] = codecs
	yap_video_set_codecs(i32(stream), i32(transmute(u8)codecs))
}

// share_start opens the browser's picker and shares what is picked as
// `config` says (its size, frame rate, bitrate and encoder; the browser
// whether the pointer shows).
share_start :: proc(config: Share_Config) {
	yap_video_share_start(
		i32(config.fps),
		i32(config.kbit),
		config.max.x,
		config.max.y,
		strings.clone_to_cstring(config.encoder, context.temp_allocator),
	)
	log.infof(
		"video: sharing at %d fps, %d kbit/s, at most %dx%d%s%s",
		config.fps,
		config.kbit,
		config.max.x,
		config.max.y,
		", with " if config.encoder != "" else "",
		config.encoder,
	)
}

share_stop :: proc() {
	yap_video_stop(i32(proto.Video_Stream.Screen))
}

share_state :: proc() -> Share_State {
	return Share_State(yap_video_state(i32(proto.Video_Stream.Screen)))
}

// can_camera says whether a camera can be turned on here at all (not
// whether there is one: the browser says that when it is asked).
can_camera :: proc() -> bool {
	return yap_video_can_camera() != 0
}

// camera_start turns on the camera `device` ("" for the browser's choice,
// a phone's front camera) as `config` says. The browser asks for permission
// the first time.
camera_start :: proc(config: Share_Config, device := "") {
	yap_video_camera_start(
		i32(config.fps),
		i32(config.kbit),
		config.max.x,
		config.max.y,
		strings.clone_to_cstring(device, context.temp_allocator),
		strings.clone_to_cstring(config.encoder, context.temp_allocator),
	)
	log.infof(
		"video: camera at %d fps, %d kbit/s, at most %dx%d",
		config.fps,
		config.kbit,
		config.max.x,
		config.max.y,
	)
}

// camera_configure has the camera go on as `config` says (its size,
// frame rate and bitrate), from a keyframe: the room's tier changed
// (video.odin).
camera_configure :: proc(config: Share_Config) {
	yap_video_camera_configure(i32(config.fps), i32(config.kbit), config.max.x, config.max.y)
}

camera_stop :: proc() {
	yap_video_stop(i32(proto.Video_Stream.Camera))
}

// camera_pause stops encoding the camera while nobody watches it, and
// goes on from a keyframe when `paused` is false again (video.odin).
camera_pause :: proc(paused: bool) {
	yap_video_camera_pause(1 if paused else 0)
}

// cameras lists the cameras as the browser last said, allocated with
// `allocator`. Before the page has been allowed a camera they have neither
// ids nor names.
cameras :: proc(allocator := context.temp_allocator) -> []Camera_Device {
	n := int(yap_video_camera_count())
	out := make([dynamic]Camera_Device, 0, n, allocator)
	for i in 0 ..< n {
		id, name: [512]u8
		if yap_video_camera_info(i32(i), &id[0], len(id), &name[0], len(name)) != 0 {
			append(
				&out,
				Camera_Device {
					id = strings.clone_from_cstring(cstring(&id[0]), allocator),
					name = strings.clone_from_cstring(cstring(&name[0]), allocator),
				},
			)
		}
	}
	return out[:]
}

// cameras_refresh has the browser list its cameras again; the answer
// comes in a later frame.
cameras_refresh :: proc() {
	yap_video_cameras_refresh()
}

// camera_look opens the camera `device` for the settings' preview while
// ours is off, without sending it; the browser asks the first time. Turning
// the camera on then takes it (video.js).
camera_look :: proc(config: Share_Config, device: string) {
	yap_video_camera_look(
		strings.clone_to_cstring(device, context.temp_allocator),
		config.max.x,
		config.max.y,
	)
}

camera_look_stop :: proc() {
	yap_video_camera_look_stop()
}

// The browser's console says why it failed.
camera_look_state :: proc() -> (state: Share_State, why: string) {
	return Share_State(yap_video_camera_look_state()), ""
}

camera_state :: proc() -> Share_State {
	return Share_State(yap_video_state(i32(proto.Video_Stream.Camera)))
}

// camera_error says why the camera failed, or "" if only the browser's
// console says. The result is in the temp allocator.
camera_error :: proc() -> string {
	return page_why(.Camera)
}

@(private = "file")
page_why :: proc(stream: proto.Video_Stream) -> string {
	buf: [256]u8
	yap_video_why(i32(stream), &buf[0], len(buf))
	return strings.clone_from_cstring(cstring(&buf[0]), context.temp_allocator)
}

// The page lets go of its camera itself.
frame_done :: proc() {}

// The browser asks what to share in its own picker.
PICKER :: false

// The browser asks in its own picker, so nothing needs to be allowed first.
capture_allowed :: proc() -> bool {
	return true
}

allow_capture :: proc() {}

// share_kbit is the bitrate a stream's encoder runs at, which sending is
// paced for (video.odin); 0 while it isn't live.
share_kbit :: proc(stream: proto.Video_Stream) -> int {
	return int(yap_video_encoding_kbit(i32(stream)))
}

// share_max_kbit is the bitrate a stream was started at, which adapting
// never goes above; 0 while it isn't live.
share_max_kbit :: proc(stream: proto.Video_Stream) -> int {
	return int(yap_video_max_kbit(i32(stream)))
}

// share_adapt holds a stream to `kbit` for its viewers (video.odin). The
// encoder takes it up from its next frame, without a keyframe.
share_adapt :: proc(stream: proto.Video_Stream, kbit: int) {
	yap_video_set_bitrate(i32(stream), i32(kbit))
}

sources :: proc(allocator := context.temp_allocator) -> []Source {
	return nil
}

share_source :: proc(src: Source, config: Share_Config) {}

// A page has no library to look for.
library_dir :: proc(allocator := context.temp_allocator) -> string {
	return ""
}

missing_ffmpeg :: proc() -> bool {
	return false
}

// The browser's picker is ours to open, not the system's.
system_picker :: proc() -> bool {
	return false
}

// The browser says which codecs it encodes, and whether on the GPU was asked
// for, but not whose encoder it is (web/video.js).
// encoders lists the page's encoders, best first, allocated with
// `allocator`. It is empty until they have been tried; asking starts that.
encoders :: proc(allocator := context.temp_allocator) -> []Encoder {
	n := int(yap_video_encoder_count())
	if n <= 0 {
		return nil
	}
	out := make([dynamic]Encoder, 0, n, allocator)
	for i in 0 ..< n {
		name, label: [128]u8
		works: i32
		if yap_video_encoder_info(i32(i), &name[0], len(name), &label[0], len(label), &works) !=
		   0 {
			append(
				&out,
				Encoder {
					name = strings.clone_from_cstring(cstring(&name[0]), allocator),
					label = strings.clone_from_cstring(cstring(&label[0]), allocator),
					works = works != 0,
				},
			)
		}
	}
	return out[:]
}

// The page shows the picture without the library's counts.
picture_info :: proc(key: Key) -> (frames: u64, hardware: bool) {
	return 0, false
}

// The page draws each new picture as it arrives, so no waking is needed.
set_wake :: proc(wake: proc "c" ()) {}

// share_error says why sharing failed, or "" if only the browser's
// console says. The result is in the temp allocator.
share_error :: proc() -> string {
	return page_why(.Screen)
}

// A texture the page draws a stream's frames into, the size of the picture in
// it, and when the UI last drew it. One for each stream that can be watched at
// once, and one for our own camera.
@(private = "file")
Web_Picture :: struct {
	key:      Key, // user 0 and the camera: our own camera
	texture:  render.Gpu_Texture,
	size:     [2]int,
	drawn_at: time.Tick,
	used:     bool,
}

@(private = "file")
web_pictures: [STREAMS + 1]Web_Picture

// web_picture returns the picture of `key`, giving it the one drawn longest
// ago if it has none.
@(private = "file")
web_picture :: proc(key: Key) -> ^Web_Picture {
	oldest: ^Web_Picture
	for &p in web_pictures {
		if p.used && p.key == key {
			return &p
		}
		if oldest == nil ||
		   !p.used ||
		   (oldest.used && time.tick_diff(oldest.drawn_at, p.drawn_at) < 0) {
			oldest = &p
		}
	}
	oldest.key, oldest.size, oldest.used = key, {}, true
	return oldest
}

// picture is the newest frame of a stream we are watching, as a texture
// of the renderer's. The page puts each new frame into it (an OpenGL texture
// name, as the page knows it, render/gpu_gl.odin).
picture :: proc(
	g: ^render.Gpu,
	key: Key,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	if key.user == 0 {
		return
	}
	return upload(g, key)
}

// camera_preview is the newest frame of our own camera, as it is sent
// (not mirrored), for the self view. Like picture.
camera_preview :: proc(
	g: ^render.Gpu,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	return upload(g, {0, .Camera})
}

@(private = "file")
upload :: proc(
	g: ^render.Gpu,
	key: Key,
) -> (
	texture: render.Gpu_Texture,
	width, height: int,
	ok: bool,
) {
	p := web_picture(key)
	p.drawn_at = time.tick_now()
	if p.texture == 0 {
		p.texture = render.gpu_texture_make(g, .Rgba, 0, 0, nil)
	}
	w, h: i32
	if yap_video_upload(u32(key.user), i32(key.stream), u32(p.texture), &w, &h) != 0 {
		p.size = {int(w), int(h)}
	}
	if p.size.x <= 0 || p.size.y <= 0 {
		return
	}
	return p.texture, p.size.x, p.size.y, true
}

// forget_gpu forgets the textures when their device goes away.
forget_gpu :: proc(g: ^render.Gpu) {
	web_pictures = {}
}

// The whole page goes fullscreen, to show the picture (ui_video.odin).
set_fullscreen :: proc(on: bool) {
	yap_video_set_fullscreen(1 if on else 0)
}

is_fullscreen :: proc() -> bool {
	return yap_video_is_fullscreen() != 0
}
