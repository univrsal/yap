package proto

import "core:encoding/endian"
import "core:time"

// Screen sharing and cameras: a user's encoded video is forwarded by the server
// to everyone in the same room who is watching them. The web client shares
// and watches using what the browser provides (H.264), and the desktop client
// uses the optional yap_video library (H.264, HEVC or AV1). The protocol
// doesn't depend on which client is on either end, and the server never
// looks inside the video.
//
//	client -> server  Video     [kind][frame u32][ts u32][index u16][count u16][flags u8][codec u8][data]
//	server -> client  Video     [kind][sharer u32][frame u32][ts u32][index u16][count u16][flags u8][codec u8][data]
//	client -> server  Watch     [kind][sharer u32][flags u8]
//	client -> server  Watch     [kind][sharer u32][flags u8][width u16][height u16]
//	server -> client  Keyframe  [kind]
//	server -> client  Keyframe  [kind][stream u8]
//	server -> sharer  Demand    [kind][stream u8][width u16][height u16][viewers u16]
//
// A frame is split into `count` fragments, and `index` says which fragment
// this is. All but the last carry VIDEO_FRAGMENT_SIZE bytes. Frames are
// numbered consecutively, so a receiver that sees a skipped number knows that
// something is missing. `ts` is the capture time in milliseconds, which the
// decoder uses.
//
// Video depends on the frames before it, so a lost fragment spoils every
// frame up to the next keyframe. On the media link, a viewer first asks the
// server for the missing fragments (Nack, video_window.odin). The server
// keeps the last half second of every sharer's fragments. Fragments that
// can't be recovered this way, or are lost on the other links, are given up
// on, and the receiver asks for a keyframe instead: Watch with
// WATCH_NEED_KEY, which the server passes on to the sharer as a Keyframe, at
// most once every KEYFRAME_REQUEST_MIN.
//
// Watch is a lease rather than a subscription: the viewer repeats it every
// WATCH_RESEND, and the server forwards video only until WATCH_LEASE after
// the last one. Nothing needs to be acknowledged, and a viewer that
// disappears or loses its packets simply stops receiving video. A `sharer`
// of 0 stops watching immediately.
//
// Whether a user is sharing at all is shown by the Sharing flag in their
// User_Flags, which is set together with Sound and visible to everyone in the
// State snapshot.
//
// A user has up to two streams, their screen and their camera (Video_Stream).
// A camera's fragments carry VIDEO_CAMERA in their flags, and it is watched
// with WATCH_CAMERA. The messages about a stream that have no flags (Keyframe,
// Nack and Report) end with a stream byte for a camera, and without it are
// about the screen, as before there were cameras. A client that knows nothing
// of cameras never watches one, so it never receives anything about one, and
// it would drop the longer messages anyway (message_kind checks their sizes).
// Whether a user's camera is on is shown by the Camera flag. The server allows
// at most `max_cameras` of them in a channel's room (Server_Info), and none if
// it doesn't say.
//
// A viewer holds one lease on a screen at most, and watching another screen
// replaces it, but a lease on each of up to MAX_CAMERAS cameras. WATCH_STOP
// ends a lease at once.
//
// Demand: a camera goes to all of its viewers as one stream, so it need not be
// bigger than the largest of them shows it. A viewer's Watch on a camera says
// how big its tile is, in pixels, where the server says it takes that
// (Server_Info.demand). Once a second, and at once when a lease starts or a
// tile changes size, the server tells the sharer the largest tile any viewer
// in its room shows the camera at, and how many viewers there are (Demand). A
// size of 0 means that somebody didn't say, so there is no limit. With no
// viewers the sharer stops encoding until there are, or until a viewer asks
// for a keyframe. A client that knows nothing of it never gets a Demand,
// since it never sends a camera.

VIDEO_UP_HEADER_SIZE :: 1 + 4 + 4 + 2 + 2 + 1 + 1
VIDEO_DOWN_HEADER_SIZE :: VIDEO_UP_HEADER_SIZE + 4
// Sized for the server-to-client direction, which has the longer header, so
// that the server can pass a fragment on without splitting it again.
VIDEO_FRAGMENT_SIZE :: MAX_PAYLOAD_SIZE - VIDEO_DOWN_HEADER_SIZE
// The largest allowed frame size. A keyframe of a detailed screen at 1440p
// and a high bitrate can come close to it.
MAX_VIDEO_FRAME_SIZE :: 1024 * 1024
MAX_VIDEO_FRAGMENTS :: (MAX_VIDEO_FRAME_SIZE + VIDEO_FRAGMENT_SIZE - 1) / VIDEO_FRAGMENT_SIZE

WATCH_SIZE :: 1 + 4 + 1
WATCH_TILE_SIZE :: WATCH_SIZE + 2 + 2
DEMAND_SIZE :: 1 + 1 + 2 + 2 + 2
KEYFRAME_SIZE :: 1
KEYFRAME_CAMERA_SIZE :: KEYFRAME_SIZE + 1

// The most cameras that a server may allow in one room.
MAX_CAMERAS :: 16

WATCH_RESEND :: 1 * time.Second
WATCH_LEASE :: 3 * time.Second
KEYFRAME_REQUEST_MIN :: 500 * time.Millisecond

// Watch flags.
WATCH_NEED_KEY :: 1 << 0
WATCH_CAMERA :: 1 << 1 // the lease is on the sharer's camera, not their screen
WATCH_STOP :: 1 << 2 // ends the lease instead of renewing it

// Video flags.
VIDEO_KEY :: 1 << 0
VIDEO_CAMERA :: 1 << 1 // a fragment of the sharer's camera, not their screen

// Video_Stream is which of a user's streams a message is about. The numbers are
// the stream byte of Keyframe, Nack and Report.
Video_Stream :: enum u8 {
	Screen = 0,
	Camera = 1,
}

// stream_flag returns the user flag that says that a stream is on.
stream_flag :: proc(stream: Video_Stream) -> User_Flag {
	return .Camera if stream == .Camera else .Sharing
}

// put_stream ends a message that is `size` bytes long for the screen with the
// stream byte if it is about the camera, and returns its size.
@(private)
put_stream :: proc(out: []u8, size: int, stream: Video_Stream) -> int {
	if stream == .Screen {
		return size
	}
	out[size] = u8(stream)
	return size + 1
}

// get_stream reads the stream byte of a message that is `size` bytes long for
// the screen.
@(private)
get_stream :: proc(pt: []u8, size: int) -> (stream: Video_Stream, ok: bool) {
	switch len(pt) {
	case size:
		return .Screen, true
	case size + 1:
		if pt[size] == u8(Video_Stream.Camera) {
			return .Camera, true
		}
	}
	return
}

// How a frame is encoded. The receiver's decoder has to support it. A viewer
// that can't decode a codec shows nothing, so each client announces which
// codecs it can decode (User_Flag) and sharers stick to those.
Video_Codec :: enum u8 {
	H264 = 0, // Annex B, so each keyframe carries its own parameter sets
	HEVC = 1, // Annex B, including the VPS
	AV1  = 2, // a temporal unit of OBUs with sizes, keyframes include the sequence header
}
Video_Codecs :: bit_set[Video_Codec;u8]

// decodable_codecs returns the codecs that a user with `flags` can decode.
decodable_codecs :: proc(flags: User_Flags) -> Video_Codecs {
	codecs := Video_Codecs{.H264}
	if .Decodes_HEVC in flags {
		codecs += {.HEVC}
	}
	if .Decodes_AV1 in flags {
		codecs += {.AV1}
	}
	return codecs
}

// One fragment of a frame. `data` points into the message it came from.
Video_Fragment :: struct {
	frame:  u32,
	ts:     u32,
	index:  int,
	count:  int,
	key:    bool,
	stream: Video_Stream,
	codec:  Video_Codec,
	data:   []u8,
}

video_fragment_count :: proc(size: int) -> int {
	return (size + VIDEO_FRAGMENT_SIZE - 1) / VIDEO_FRAGMENT_SIZE
}

// video_fragment_range returns the part of a frame that fragment `index`
// carries.
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
	out[12] = (VIDEO_KEY if f.key else 0) | (VIDEO_CAMERA if f.stream == .Camera else 0)
	out[13] = u8(f.codec)
	return 14 + copy(out[14:], f.data)
}

@(private = "file")
get_video_body :: proc(body: []u8) -> (f: Video_Fragment, ok: bool) {
	f = {
		frame  = endian.unchecked_get_u32le(body[0:]),
		ts     = endian.unchecked_get_u32le(body[4:]),
		index  = int(endian.unchecked_get_u16le(body[8:])),
		count  = int(endian.unchecked_get_u16le(body[10:])),
		key    = body[12] & VIDEO_KEY != 0,
		stream = .Camera if body[12] & VIDEO_CAMERA != 0 else .Screen,
		codec  = Video_Codec(body[13]),
		data   = body[14:],
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

// encode_video_up writes a fragment to be sent to the server. `out` must have
// room for VIDEO_UP_HEADER_SIZE + len(f.data) bytes.
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

// video_up_to_down turns a sharer's fragment into the one its viewers
// receive, without looking inside it: the sharer's number is simply put in
// front. `pt` must have been checked with decode_video_up.
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

Watch :: struct {
	sharer:   User_Num, // 0 ends every lease on that kind of stream
	stream:   Video_Stream,
	need_key: bool,
	stop:     bool, // ends the lease instead of renewing it
	// How big the viewer shows it, in pixels; 0 if it didn't say.
	tile:     [2]int,
}

// encode_watch writes a Watch, with the tile's size if `tile` has one.
encode_watch :: proc(
	out: ^[WATCH_TILE_SIZE]u8,
	sharer: User_Num,
	need_key: bool,
	stream := Video_Stream.Screen,
	stop := false,
	tile := [2]int{},
) -> []u8 {
	out[0] = u8(Message_Kind.Watch)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	out[5] =
		(WATCH_NEED_KEY if need_key else 0) |
		(WATCH_CAMERA if stream == .Camera else 0) |
		(WATCH_STOP if stop else 0)
	if tile.x <= 0 || tile.y <= 0 {
		return out[:WATCH_SIZE]
	}
	endian.unchecked_put_u16le(out[6:], u16(min(tile.x, 65535)))
	endian.unchecked_put_u16le(out[8:], u16(min(tile.y, 65535)))
	return out[:]
}

decode_watch :: proc(pt: []u8) -> (w: Watch) {
	w = {
		sharer   = User_Num(endian.unchecked_get_u32le(pt[1:])),
		stream   = .Camera if pt[5] & WATCH_CAMERA != 0 else .Screen,
		need_key = pt[5] & WATCH_NEED_KEY != 0,
		stop     = pt[5] & WATCH_STOP != 0,
	}
	if len(pt) >= WATCH_TILE_SIZE {
		w.tile = {int(endian.unchecked_get_u16le(pt[6:])), int(endian.unchecked_get_u16le(pt[8:]))}
	}
	return
}

// Demand is what the server says of one of a sharer's streams: the largest
// tile any viewer shows it at (0 by 0 if one of them didn't say), and how many
// viewers there are.
Demand :: struct {
	stream:  Video_Stream,
	tile:    [2]int,
	viewers: int,
}

encode_demand :: proc(out: ^[DEMAND_SIZE]u8, d: Demand) -> []u8 {
	out[0] = u8(Message_Kind.Demand)
	out[1] = u8(d.stream)
	endian.unchecked_put_u16le(out[2:], u16(clamp(d.tile.x, 0, 65535)))
	endian.unchecked_put_u16le(out[4:], u16(clamp(d.tile.y, 0, 65535)))
	endian.unchecked_put_u16le(out[6:], u16(clamp(d.viewers, 0, 65535)))
	return out[:]
}

@(require_results)
decode_demand :: proc(pt: []u8) -> (d: Demand, ok: bool) {
	if len(pt) != DEMAND_SIZE || pt[1] > u8(max(Video_Stream)) {
		return
	}
	return {
			stream = Video_Stream(pt[1]),
			tile = {
				int(endian.unchecked_get_u16le(pt[2:])),
				int(endian.unchecked_get_u16le(pt[4:])),
			},
			viewers = int(endian.unchecked_get_u16le(pt[6:])),
		},
		true
}

encode_keyframe :: proc(out: ^[KEYFRAME_CAMERA_SIZE]u8, stream := Video_Stream.Screen) -> []u8 {
	out[0] = u8(Message_Kind.Keyframe)
	return out[:put_stream(out[:], KEYFRAME_SIZE, stream)]
}

@(require_results)
decode_keyframe :: proc(pt: []u8) -> (stream: Video_Stream, ok: bool) {
	return get_stream(pt, KEYFRAME_SIZE)
}

// A frame as it comes out of a Video_Window (video_window.odin).
Video_Frame :: struct {
	frame: u32,
	ts:    u32,
	key:   bool,
	codec: Video_Codec,
	data:  []u8, // valid until the window's next video_window_add call
}
