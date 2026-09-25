#+build !wasi
package client

import "core:testing"

import "../proto"

// An encoded frame of `size` bytes, owned by whoever it's handed to.
@(private = "file")
encoded :: proc(size: int, seed: u8) -> []u8 {
	data := make([]u8, size)
	for &b, i in data {
		b = u8(i) ~ seed
	}
	return data
}

@(private = "file")
video_free :: proc(v: ^Video_Client) {
	video_clear_queue(v)
	delete(v.queue)
}

// send_all takes every fragment off the queue and passes it through the
// server's rewrite into `a`, returning the frames that came out.
@(private = "file")
send_all :: proc(v: ^Video_Client, a: ^proto.Video_Assembler) -> (frames: [dynamic]proto.Video_Frame) {
	frames = make([dynamic]proto.Video_Frame, context.temp_allocator)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	for {
		up, ok := video_next_fragment(v, buf[:])
		if !ok {
			return
		}
		down_buf: [proto.MAX_PAYLOAD_SIZE]u8
		down := proto.video_up_to_down(&down_buf, 3, up)
		_, f, down_ok := proto.decode_video_down(down)
		if !down_ok {
			return
		}
		if frame, complete := proto.video_assembler_add(a, f); complete {
			frame.data = copy_slice(frame.data)
			append(&frames, frame)
		}
	}
}

@(private = "file")
copy_slice :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}

@(test)
test_video_queue_roundtrip :: proc(t: ^testing.T) {
	v: Video_Client
	defer video_free(&v)
	a := new(proto.Video_Assembler)
	defer free(a)
	proto.video_assembler_reset(a)

	sizes := []int{3 * proto.VIDEO_FRAGMENT_SIZE + 100, 900, proto.VIDEO_FRAGMENT_SIZE}
	want := make([][]u8, len(sizes), context.temp_allocator)
	for size, i in sizes {
		data := encoded(size, u8(i))
		want[i] = copy_slice(data)
		video_queue_frame(&v, data, u32(i * 66), i == 0)
	}
	frames := send_all(&v, a)
	testing.expect_value(t, len(frames), len(sizes))
	for f, i in frames {
		testing.expect_value(t, f.frame, u32(i))
		testing.expect_value(t, f.ts, u32(i * 66))
		testing.expect_value(t, f.key, i == 0)
		testing.expect(t, string(f.data) == string(want[i]))
	}
	testing.expect_value(t, v.queued_bytes, 0)
}

@(test)
test_video_queue_falls_behind :: proc(t: ^testing.T) {
	v: Video_Client
	defer video_free(&v)

	// Enough queued to be over the limit, and the first frame started.
	size := 100 * 1024
	video_queue_frame(&v, encoded(size, 1), 0, true)
	for v.queued_bytes <= VIDEO_QUEUE_MAX {
		video_queue_frame(&v, encoded(size, 2), 0, false)
	}
	queued := len(v.queue)
	buf: [proto.MAX_PAYLOAD_SIZE]u8
	_, ok := video_next_fragment(&v, buf[:])
	testing.expect(t, ok)

	// The next frame finds the queue too long: all but the frame going
	// out is dropped, and so is it, being a delta.
	video_queue_frame(&v, encoded(10, 3), 0, false)
	testing.expect_value(t, len(v.queue), 1)
	testing.expect_value(t, v.queued_bytes, size)
	testing.expect(t, v.awaiting_key)
	testing.expect(t, v.want_key)

	// Nothing but a keyframe gets in until one comes.
	video_queue_frame(&v, encoded(10, 4), 0, false)
	testing.expect_value(t, len(v.queue), 1)
	video_queue_frame(&v, encoded(10, 5), 0, true)
	testing.expect_value(t, len(v.queue), 2)
	testing.expect(t, !v.awaiting_key)

	// Its number leaves a gap where the dropped frames were, so viewers
	// know they missed something.
	testing.expect_value(t, v.queue[1].num, u32(queued))
}

@(test)
test_video_queue_too_big :: proc(t: ^testing.T) {
	v: Video_Client
	defer video_free(&v)
	video_queue_frame(&v, encoded(proto.MAX_VIDEO_FRAME_SIZE + 1, 0), 0, true)
	testing.expect_value(t, len(v.queue), 0)
	testing.expect(t, v.want_key)
}
