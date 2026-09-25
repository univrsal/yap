#+build wasi
package client

import "../proto"

/*
Screen sharing in the browser: the page captures, encodes and decodes
(Module.yapVideo in web/video.js, reached through web/shell.c), and the
client carries the encoded frames (video.odin).
*/

@(private = "file", default_calling_convention = "c")
foreign _ {
	// 1 while the capture is running.
	yap_video_live :: proc() -> i32 ---
	// The size of the oldest encoded frame waiting, or -1 for none.
	yap_video_next_size :: proc() -> i32 ---
	// Copies the oldest encoded frame into buf and returns its size, or
	// -1 if there's none (or it doesn't fit).
	yap_video_pull :: proc(buf: [^]u8, buf_size: i32, ts: ^u32, key: ^i32) -> i32 ---
	// Makes the next frame a keyframe.
	yap_video_request_key :: proc() ---
	// Hands a frame of `sharer`'s to the decoder.
	yap_video_show :: proc(sharer: u32, data: [^]u8, size: i32, ts: u32, key: i32, codec: i32) ---
	// Drops the decoder and clears the picture.
	yap_video_end :: proc() ---
	// 1 once after the decoder failed.
	yap_video_take_error :: proc() -> i32 ---
	yap_video_can_share :: proc() -> i32 ---
	yap_video_can_watch :: proc() -> i32 ---
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

// video_capture_pull returns the next encoded frame, which the caller
// then owns.
video_capture_pull :: proc() -> (data: []u8, ts: u32, key: bool, ok: bool) {
	size := yap_video_next_size()
	if size <= 0 {
		return
	}
	data = make([]u8, size)
	key_flag: i32
	if yap_video_pull(raw_data(data), size, &ts, &key_flag) != size {
		delete(data)
		return nil, 0, false, false
	}
	return data, ts, key_flag != 0, true
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
}

// video_show_failed says, once, that the decoder gave up on what it was
// given; it needs a keyframe to start again.
video_show_failed :: proc() -> bool {
	return yap_video_take_error() != 0
}

/*
For the UI. Starting a share opens the browser's picker, which it only
allows soon after the user clicked something, so it belongs in a button
handler.
*/

// What the page's capture is doing (web/video.js).
Share_State :: enum i32 {
	Off      = 0,
	Starting = 1, // the browser's picker is open
	Live     = 2,
	Failed   = 3, // it couldn't start, or stopped with an error
}

video_can_share :: proc() -> bool {
	return yap_video_can_share() != 0
}

video_can_watch :: proc() -> bool {
	return yap_video_can_watch() != 0
}

video_share_start :: proc() {
	yap_video_share_start()
}

video_share_stop :: proc() {
	yap_video_share_stop()
}

video_share_state :: proc() -> Share_State {
	return Share_State(yap_video_share_state())
}

// video_upload puts the newest frame of what we're watching into
// `texture`, if one has come since the last call, and says its size.
video_upload :: proc(texture: u32) -> (width, height: int, ok: bool) {
	w, h: i32
	if yap_video_upload(texture, &w, &h) == 0 {
		return
	}
	return int(w), int(h), true
}

// The whole page fullscreen, for the picture (ui_video.odin).
video_set_fullscreen :: proc(on: bool) {
	yap_video_set_fullscreen(1 if on else 0)
}

video_is_fullscreen :: proc() -> bool {
	return yap_video_is_fullscreen() != 0
}
