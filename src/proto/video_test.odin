#+build !wasi
package proto

import "core:testing"

// A frame of `size` bytes, each byte saying where it is.
@(private = "file")
make_frame :: proc(size: int) -> []u8 {
	data := make([]u8, size, context.temp_allocator)
	for &b, i in data {
		b = u8(i * 7)
	}
	return data
}

// The fragments of frame `num`, encoded as the server sends them and
// decoded again.
@(private = "file")
fragments :: proc(num: u32, key: bool, data: []u8) -> []Video_Fragment {
	count := video_fragment_count(len(data))
	out := make([]Video_Fragment, count, context.temp_allocator)
	for i in 0 ..< count {
		start, end := video_fragment_range(len(data), i)
		buf := make([]u8, MAX_PAYLOAD_SIZE, context.temp_allocator)
		msg := encode_video_down(
			buf,
			9,
			{frame = num, ts = num * 100, index = i, count = count, key = key, data = data[start:end]},
		)
		sharer, f, ok := decode_video_down(msg)
		assert(ok && sharer == 9)
		out[i] = f
	}
	return out
}

// feed gives an assembler every fragment and returns what came out.
@(private = "file")
feed :: proc(a: ^Video_Assembler, fs: []Video_Fragment) -> (frame: Video_Frame, complete: bool) {
	for f in fs {
		if got, ok := video_assembler_add(a, f); ok {
			frame, complete = got, true
		}
	}
	return
}

@(test)
test_video_roundtrip :: proc(t: ^testing.T) {
	data := make_frame(3 * VIDEO_FRAGMENT_SIZE + 17)
	buf: [MAX_PAYLOAD_SIZE]u8
	sent := Video_Fragment {
		frame = 41,
		ts    = 1234,
		index = 3,
		count = 4,
		key   = true,
		codec = .H264,
		data  = data[3 * VIDEO_FRAGMENT_SIZE:],
	}
	up := encode_video_up(buf[:], sent)
	kind, ok := message_kind(up)
	testing.expect(t, ok)
	testing.expect_value(t, kind, Message_Kind.Video)
	got, up_ok := decode_video_up(up)
	testing.expect(t, up_ok)
	testing.expect_value(t, got.frame, 41)
	testing.expect_value(t, got.ts, 1234)
	testing.expect_value(t, got.index, 3)
	testing.expect_value(t, got.count, 4)
	testing.expect(t, got.key)
	testing.expect_value(t, len(got.data), 17)

	// The server's rewrite is the same as encoding it for the way down.
	down_buf: [MAX_PAYLOAD_SIZE]u8
	down := video_up_to_down(&down_buf, 5, up)
	sharer, f, down_ok := decode_video_down(down)
	testing.expect(t, down_ok)
	testing.expect_value(t, sharer, 5)
	testing.expect_value(t, f.frame, 41)
	testing.expect_value(t, string(f.data), string(sent.data))

	// A full fragment still fits the way down.
	full := sent
	full.index, full.data = 0, data[:VIDEO_FRAGMENT_SIZE]
	up = encode_video_up(buf[:], full)
	down = video_up_to_down(&down_buf, 5, up)
	testing.expect_value(t, len(down), MAX_PAYLOAD_SIZE)
	_, _, down_ok = decode_video_down(down)
	testing.expect(t, down_ok)
}

@(test)
test_video_rejects :: proc(t: ^testing.T) {
	buf: [MAX_PAYLOAD_SIZE]u8
	data := make_frame(VIDEO_FRAGMENT_SIZE)
	bad := []Video_Fragment {
		{index = 0, count = 0, data = data[:10]}, // no fragments
		{index = 2, count = 2, data = data[:10]}, // index past the end
		{index = 0, count = MAX_VIDEO_FRAGMENTS + 1, data = data}, // too big a frame
		{index = 0, count = 2, data = data[:10]}, // a short fragment that isn't the last
	}
	for f in bad {
		_, ok := decode_video_up(encode_video_up(buf[:], f))
		testing.expect(t, !ok)
	}
	_, ok := decode_video_up(encode_video_up(buf[:], {count = 1}))
	testing.expect(t, !ok) // nothing in it
}

@(test)
test_watch_roundtrip :: proc(t: ^testing.T) {
	buf: [WATCH_SIZE]u8
	msg := encode_watch(&buf, 12, true)
	kind, ok := message_kind(msg)
	testing.expect(t, ok)
	testing.expect_value(t, kind, Message_Kind.Watch)
	sharer, need_key := decode_watch(msg)
	testing.expect_value(t, sharer, 12)
	testing.expect(t, need_key)

	_, ok = message_kind(msg[:WATCH_SIZE - 1])
	testing.expect(t, !ok)

	key_buf: [KEYFRAME_SIZE]u8
	kind, ok = message_kind(encode_keyframe(&key_buf))
	testing.expect(t, ok)
	testing.expect_value(t, kind, Message_Kind.Keyframe)
}

@(test)
test_assembler_waits_for_key :: proc(t: ^testing.T) {
	a := new(Video_Assembler)
	defer free(a)
	video_assembler_reset(a)

	// A delta before any keyframe has nothing to decode against.
	_, ok := feed(a, fragments(1, false, make_frame(500)))
	testing.expect(t, !ok)
	testing.expect(t, a.broken)

	key := make_frame(2 * VIDEO_FRAGMENT_SIZE + 5)
	frame: Video_Frame
	frame, ok = feed(a, fragments(2, true, key))
	testing.expect(t, ok)
	testing.expect(t, !a.broken)
	testing.expect(t, frame.key)
	testing.expect_value(t, frame.ts, 200)
	testing.expect_value(t, string(frame.data), string(key))

	delta := make_frame(40)
	frame, ok = feed(a, fragments(3, false, delta))
	testing.expect(t, ok)
	testing.expect_value(t, string(frame.data), string(delta))
}

@(test)
test_assembler_out_of_order :: proc(t: ^testing.T) {
	a := new(Video_Assembler)
	defer free(a)
	video_assembler_reset(a)

	key := make_frame(3 * VIDEO_FRAGMENT_SIZE)
	fs := fragments(1, true, key)
	fs[0], fs[2] = fs[2], fs[0]
	frame, ok := feed(a, fs)
	testing.expect(t, ok)
	testing.expect_value(t, string(frame.data), string(key))

	// A repeat of a finished frame is ignored.
	_, ok = video_assembler_add(a, fs[1])
	testing.expect(t, !ok)
}

@(test)
test_assembler_loss :: proc(t: ^testing.T) {
	a := new(Video_Assembler)
	defer free(a)
	video_assembler_reset(a)
	_, ok := feed(a, fragments(1, true, make_frame(100)))
	testing.expect(t, ok)

	// Frame 2 loses a fragment; frame 3 arriving gives it up.
	lossy := fragments(2, false, make_frame(2 * VIDEO_FRAGMENT_SIZE))
	_, ok = feed(a, lossy[:1])
	testing.expect(t, !ok)
	testing.expect(t, !a.broken)
	_, ok = feed(a, fragments(3, false, make_frame(10)))
	testing.expect(t, !ok)
	testing.expect(t, a.broken)

	// The late fragment of frame 2 changes nothing.
	_, ok = video_assembler_add(a, lossy[1])
	testing.expect(t, !ok)

	_, ok = feed(a, fragments(4, true, make_frame(100)))
	testing.expect(t, ok)
	testing.expect(t, !a.broken)

	// A frame number skipped outright is a loss too.
	_, ok = feed(a, fragments(6, false, make_frame(10)))
	testing.expect(t, !ok)
	testing.expect(t, a.broken)
}

@(test)
test_assembler_largest_frame :: proc(t: ^testing.T) {
	a := new(Video_Assembler)
	defer free(a)
	video_assembler_reset(a)
	data := make_frame(MAX_VIDEO_FRAGMENTS * VIDEO_FRAGMENT_SIZE)
	frame, ok := feed(a, fragments(1, true, data))
	testing.expect(t, ok)
	testing.expect_value(t, len(frame.data), len(data))
}
