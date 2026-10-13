package proto

import "core:encoding/endian"
import "core:time"

/*
Screen sharing: a user's encoded video, forwarded by the server to
whoever in the same channel is watching them. The web client shares and
watches with what the browser has (H.264); the desktop client with the
optional yap_video library (H.264, HEVC or AV1). The protocol doesn't
care who's on either end, and the server never looks inside the video.

	client -> server  Video     [kind][frame u32][ts u32][index u16][count u16][flags u8][codec u8][data]
	server -> client  Video     [kind][sharer u32][frame u32][ts u32][index u16][count u16][flags u8][codec u8][data]
	client -> server  Watch     [kind][sharer u32][flags u8]
	server -> client  Keyframe  [kind]

A frame is split into `count` fragments, `index` saying which this is;
all but the last carry VIDEO_FRAGMENT_SIZE bytes. Frames are numbered
one after the other, so a receiver that sees a number skipped knows
something is missing. `ts` is the capture time in milliseconds, for the
decoder.

Video depends on the frames before it, so a lost fragment spoils every
frame up to the next keyframe. On the media link a viewer first asks the
server for what's missing (Nack, video_window.odin), which keeps the
last half second of every sharer's fragments; what can't be had that
way, or on the other links, is given up on, and the receiver asks for a
keyframe: Watch with WATCH_NEED_KEY, which the server passes on to the
sharer as a Keyframe, at most once every KEYFRAME_REQUEST_MIN.

Watch is a lease rather than a subscription: the viewer repeats it every
WATCH_RESEND and the server forwards video only until WATCH_LEASE after
the last one. Nothing needs acknowledging, and a viewer that vanishes or
loses its packets simply stops getting video. `sharer` 0 stops watching
right away.

Whether a user is sharing at all is the Sharing flag in their User_Flags,
set with Sound and seen by everyone in the State snapshot.
*/

VIDEO_UP_HEADER_SIZE :: 1 + 4 + 4 + 2 + 2 + 1 + 1
VIDEO_DOWN_HEADER_SIZE :: VIDEO_UP_HEADER_SIZE + 4
// Sized for the way down, which has the longer header, so the server
// can pass a fragment on without splitting it again.
VIDEO_FRAGMENT_SIZE :: MAX_PAYLOAD_SIZE - VIDEO_DOWN_HEADER_SIZE
// The largest frame, which a keyframe of a detailed screen at 1440p
// and a high bitrate can come close to.
MAX_VIDEO_FRAME_SIZE :: 1024 * 1024
MAX_VIDEO_FRAGMENTS :: (MAX_VIDEO_FRAME_SIZE + VIDEO_FRAGMENT_SIZE - 1) / VIDEO_FRAGMENT_SIZE

WATCH_SIZE :: 1 + 4 + 1
KEYFRAME_SIZE :: 1

WATCH_RESEND :: 1 * time.Second
WATCH_LEASE :: 3 * time.Second
KEYFRAME_REQUEST_MIN :: 500 * time.Millisecond

// Watch flags.
WATCH_NEED_KEY :: 1 << 0

// Video flags.
VIDEO_KEY :: 1 << 0

// How a frame is encoded; the receiver's decoder has to agree. A viewer
// that can't decode a codec shows nothing (the web client only H.264).
Video_Codec :: enum u8 {
	H264 = 0, // Annex B, so each keyframe carries its own parameter sets
	HEVC = 1, // Annex B, with the VPS too
	AV1  = 2, // a temporal unit of OBUs with sizes; keyframes with the sequence header
}

// One fragment of a frame. `data` points into the message it came from.
Video_Fragment :: struct {
	frame: u32,
	ts:    u32,
	index: int,
	count: int,
	key:   bool,
	codec: Video_Codec,
	data:  []u8,
}

video_fragment_count :: proc(size: int) -> int {
	return (size + VIDEO_FRAGMENT_SIZE - 1) / VIDEO_FRAGMENT_SIZE
}

// video_fragment_range is the part of a frame fragment `index` carries.
video_fragment_range :: proc(size, index: int) -> (start, end: int) {
	start = index * VIDEO_FRAGMENT_SIZE
	return start, min(start + VIDEO_FRAGMENT_SIZE, size)
}

@(private = "file")
put_video_body :: proc(out: []u8, f: Video_Fragment) -> int {
	endian.unchecked_put_u32le(out[0:], f.frame)
	endian.unchecked_put_u32le(out[4:], f.ts)
	endian.unchecked_put_u16le(out[8:], u16(f.index))
	endian.unchecked_put_u16le(out[10:], u16(f.count))
	out[12] = VIDEO_KEY if f.key else 0
	out[13] = u8(f.codec)
	return 14 + copy(out[14:], f.data)
}

@(private = "file")
get_video_body :: proc(body: []u8) -> (f: Video_Fragment, ok: bool) {
	f = {
		frame = endian.unchecked_get_u32le(body[0:]),
		ts    = endian.unchecked_get_u32le(body[4:]),
		index = int(endian.unchecked_get_u16le(body[8:])),
		count = int(endian.unchecked_get_u16le(body[10:])),
		key   = body[12] & VIDEO_KEY != 0,
		codec = Video_Codec(body[13]),
		data  = body[14:],
	}
	switch {
	case f.count == 0 || f.count > MAX_VIDEO_FRAGMENTS || f.index >= f.count:
		return
	case len(f.data) == 0 || len(f.data) > VIDEO_FRAGMENT_SIZE:
		return
	case f.index < f.count - 1 && len(f.data) != VIDEO_FRAGMENT_SIZE:
		return
	}
	return f, true
}

// encode_video_up writes a fragment for the server; `out` must hold
// VIDEO_UP_HEADER_SIZE + len(f.data).
encode_video_up :: proc(out: []u8, f: Video_Fragment) -> []u8 {
	out[0] = u8(Message_Kind.Video)
	return out[:1 + put_video_body(out[1:], f)]
}

@(require_results)
decode_video_up :: proc(pt: []u8) -> (f: Video_Fragment, ok: bool) {
	if len(pt) <= VIDEO_UP_HEADER_SIZE {
		return
	}
	return get_video_body(pt[1:])
}

encode_video_down :: proc(out: []u8, sharer: User_Num, f: Video_Fragment) -> []u8 {
	out[0] = u8(Message_Kind.Video)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	return out[:5 + put_video_body(out[5:], f)]
}

/*
video_up_to_down turns a sharer's fragment into the one its viewers get,
without looking inside: just the sharer's number put in front. `pt` must
have been checked with decode_video_up.
*/
video_up_to_down :: proc(out: ^[MAX_PAYLOAD_SIZE]u8, sharer: User_Num, pt: []u8) -> []u8 {
	out[0] = u8(Message_Kind.Video)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	n := copy(out[5:], pt[1:])
	return out[:5 + n]
}

@(require_results)
decode_video_down :: proc(pt: []u8) -> (sharer: User_Num, f: Video_Fragment, ok: bool) {
	if len(pt) <= VIDEO_DOWN_HEADER_SIZE {
		return
	}
	f, ok = get_video_body(pt[5:])
	return User_Num(endian.unchecked_get_u32le(pt[1:])), f, ok
}

encode_watch :: proc(out: ^[WATCH_SIZE]u8, sharer: User_Num, need_key: bool) -> []u8 {
	out[0] = u8(Message_Kind.Watch)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	out[5] = WATCH_NEED_KEY if need_key else 0
	return out[:]
}

decode_watch :: proc(pt: []u8) -> (sharer: User_Num, need_key: bool) {
	return User_Num(endian.unchecked_get_u32le(pt[1:])), pt[5] & WATCH_NEED_KEY != 0
}

encode_keyframe :: proc(out: ^[KEYFRAME_SIZE]u8) -> []u8 {
	out[0] = u8(Message_Kind.Keyframe)
	return out[:]
}

// A frame as it comes out of a Video_Window (video_window.odin).
Video_Frame :: struct {
	frame: u32,
	ts:    u32,
	key:   bool,
	codec: Video_Codec,
	data:  []u8, // valid until the window's next video_window_add
}
