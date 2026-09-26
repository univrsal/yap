#+build !wasi
package client

import "../proto"

/*
A desktop build neither shares nor watches screens: that takes a video
encoder and decoder, which only the browser brings along (see
video_web.odin). It still shows who is sharing.
*/

video_capture_live :: proc() -> bool {
	return false
}

video_capture_pull :: proc() -> (data: []u8, ts: u32, key: bool, ok: bool) {
	return
}

video_capture_request_key :: proc() {}

video_show_frame :: proc(sharer: proto.User_Num, frame: proto.Video_Frame) {}

video_show_end :: proc() {}

video_show_failed :: proc() -> bool {
	return false
}

Share_State :: enum i32 {
	Off,
	Starting,
	Live,
	Failed,
}

video_can_share :: proc() -> bool {
	return false
}

video_can_watch :: proc() -> bool {
	return false
}

video_share_start :: proc() {}

video_share_stop :: proc() {}

video_share_state :: proc() -> Share_State {
	return .Off
}

video_upload :: proc(texture: Gpu_Texture) -> (width, height: int, ok: bool) {
	return
}

video_set_fullscreen :: proc(on: bool) {}

video_is_fullscreen :: proc() -> bool {
	return false
}
