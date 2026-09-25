package proto

import "core:encoding/endian"
import "core:time"

/*
Screen sharing: a user's encoded video, forwarded by the server to
whoever in the same channel is watching them. Only the web client shares
or watches (the browser does the capturing, encoding and decoding), but
the protocol doesn't care who's on either end.

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
frame up to the next keyframe. The receiver then asks for one: Watch
with WATCH_NEED_KEY, which the server passes on to the sharer as a
Keyframe, at most once every KEYFRAME_REQUEST_MIN.

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
// The largest frame, which a keyframe of a detailed screen can come
// close to at a sharp enough quality.
MAX_VIDEO_FRAME_SIZE :: 256 * 1024
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

// How a frame is encoded; the receiver's decoder has to agree.
Video_Codec :: enum u8 {
	H264 = 0, // Annex B, so each keyframe carries its own parameter sets
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

// A frame as it comes out of a Video_Assembler.
Video_Frame :: struct {
	frame: u32,
	ts:    u32,
	key:   bool,
	codec: Video_Codec,
	data:  []u8, // valid until the assembler's next call
}

/*
Video_Assembler puts one sharer's frames back together for the decoder.

It works on one frame at a time: fragments come in order unless
something went wrong, so a fragment of a newer frame means the one
being collected will never be complete. Losing a frame, or seeing a
frame number skipped, means everything up to the next keyframe would
decode wrong, so from then on `broken` is set and only a keyframe gets
through. It starts out broken, as there's nothing to decode against
yet.

It's large (a whole frame's buffer), so allocate it rather than keeping
it on the stack.
*/
Video_Assembler :: struct {
	broken:    bool,
	active:    bool, // collecting `frame`
	frame:     u32,
	ts:        u32,
	key:       bool,
	codec:     Video_Codec,
	count:     int,
	received:  int,
	size:      int,
	have:      [MAX_VIDEO_FRAGMENTS]bool,
	// The newest frame finished or given up on; nothing older is taken.
	last:      u32,
	have_last: bool,
	// Room for every fragment full, a little over MAX_VIDEO_FRAME_SIZE.
	buf:       [MAX_VIDEO_FRAGMENTS * VIDEO_FRAGMENT_SIZE]u8,
}

// video_assembler_reset readies an assembler for a new sharer.
video_assembler_reset :: proc(a: ^Video_Assembler) {
	a.broken, a.active, a.have_last = true, false, false
}

/*
video_assembler_add feeds in a fragment. When it completes a frame that
can be decoded, it returns it; a complete frame that can't (a delta
while broken) is dropped.
*/
@(require_results)
video_assembler_add :: proc(a: ^Video_Assembler, f: Video_Fragment) -> (frame: Video_Frame, complete: bool) {
	if a.have_last && !serial_newer(f.frame, a.last) {
		return // late, or a repeat
	}
	if a.active && f.frame != a.frame {
		if !serial_newer(f.frame, a.frame) {
			return
		}
		// The frame we were collecting won't be finished.
		a.broken = true
		a.last, a.have_last = a.frame, true
		a.active = false
	}
	if !a.active {
		if a.have_last && f.frame != a.last + 1 {
			a.broken = true // a whole frame went missing
		}
		a.active = true
		a.frame, a.ts, a.key, a.codec, a.count = f.frame, f.ts, f.key, f.codec, f.count
		a.received, a.size = 0, 0
		a.have = {}
	} else if f.count != a.count || f.key != a.key {
		return // doesn't belong with the others
	}

	if a.have[f.index] {
		return
	}
	a.have[f.index] = true
	a.received += 1
	start := f.index * VIDEO_FRAGMENT_SIZE
	copy(a.buf[start:], f.data)
	if f.index == f.count - 1 {
		a.size = start + len(f.data)
	}
	if a.received < a.count {
		return
	}

	a.active = false
	a.last, a.have_last = a.frame, true
	if a.key {
		a.broken = false
	} else if a.broken {
		return
	}
	return {frame = a.frame, ts = a.ts, key = a.key, codec = a.codec, data = a.buf[:a.size]}, true
}
