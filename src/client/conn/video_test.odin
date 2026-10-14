#+build !wasi
package conn

import "core:testing"
import "core:time"

import "common:proto"

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
send_all :: proc(
	v: ^Video_Client,
	w: ^proto.Video_Window,
) -> (
	frames: [dynamic]proto.Video_Frame,
) {
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
		proto.video_window_add(w, f, {})
		for {
			frame := proto.video_window_pop(w) or_break
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
	w := new(proto.Video_Window)
	defer free(w)
	defer proto.video_window_destroy(w)
	proto.video_window_reset(w)

	sizes := []int{3 * proto.VIDEO_FRAGMENT_SIZE + 100, 900, proto.VIDEO_FRAGMENT_SIZE}
	want := make([][]u8, len(sizes), context.temp_allocator)
	for size, i in sizes {
		data := encoded(size, u8(i))
		want[i] = copy_slice(data)
		video_queue_frame(&v, data, u32(i * 66), i == 0)
	}
	frames := send_all(&v, w)
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

/*
Loss, and getting it back: frames go out through the queue and the
server's rewrite as in the roundtrip, but every 10th fragment is lost
on the way. The server's cache (a map here) answers the window's Nacks
a little later, as the media link would, and every frame comes out,
in order, with nothing given up and no keyframe needed.
*/
@(test)
test_video_loss_repaired :: proc(t: ^testing.T) {
	v: Video_Client
	defer video_free(&v)
	w := new(proto.Video_Window)
	defer free(w)
	defer proto.video_window_destroy(w)
	proto.video_window_reset(w)

	cache := make(map[u64][]u8, context.temp_allocator)
	now: time.Tick
	now._nsec = 1_000_000_000
	tick := 16 * time.Millisecond
	FRAMES :: 120
	got := 0
	dropped := 0
	sent := 0
	for i in 0 ..< FRAMES {
		size := 4 * proto.VIDEO_FRAGMENT_SIZE + 100 if i % 10 == 0 else 900 + i
		video_queue_frame(&v, encoded(size, u8(i)), u32(i * 16), i == 0)
		buf: [proto.MAX_PAYLOAD_SIZE]u8
		for {
			up := video_next_fragment(&v, buf[:]) or_break
			down_buf: [proto.MAX_PAYLOAD_SIZE]u8
			down := proto.video_up_to_down(&down_buf, 3, up)
			_, f, ok := proto.decode_video_down(down)
			testing.expect(t, ok)
			cache[u64(f.frame) << 16 | u64(f.index)] = slice_clone(down)
			sent += 1
			if sent % 10 == 0 {
				dropped += 1
				continue
			}
			proto.video_window_add(w, f, now)
		}
		// A frame's time passes; what's asked for comes back the next.
		for step in 0 ..< 4 {
			now = time.tick_add(now, tick / 4)
			for n in proto.video_window_nacks(w, now, true) {
				for bit in 0 ..< proto.NACK_SPAN {
					if n.missing & (u64(1) << uint(bit)) == 0 {
						continue
					}
					msg, have := cache[u64(n.frame) << 16 | u64(n.first + bit)]
					if !have {
						continue
					}
					_, f, _ := proto.decode_video_down(msg)
					proto.video_window_add(w, f, time.tick_add(now, 5 * time.Millisecond))
				}
			}
			_ = step
			for {
				frame := proto.video_window_pop(w) or_break
				testing.expect_value(t, frame.frame, u32(got))
				got += 1
			}
		}
	}
	testing.expect(t, dropped > 10)
	testing.expect_value(t, got, FRAMES)
	testing.expect_value(t, w.given_up, 0)
	testing.expect(t, !w.broken)
	testing.expect(t, w.recovered > 0)
}

@(private = "file")
slice_clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}

/*
adapt_bitrate, fed reports at made-up times: down a quarter when a
viewer loses fragments or falls behind, not again until ADAPT_CUT_EVERY,
down to what reaches them, never under the floor; up a fifth after
ADAPT_GOOD_FOR of good reports, and back to as set.
*/
@(test)
test_adapt_bitrate :: proc(t: ^testing.T) {
	v: Video_Client
	at := time.tick_now()
	later :: proc(at: time.Tick, d: time.Duration) -> time.Tick {
		return time.tick_add(at, d)
	}
	MAX :: 8000
	bad := proto.Video_Report {
		loss     = 50,
		delay_ms = 10,
		kbit     = 8000,
	}
	good := proto.Video_Report {
		loss     = 0,
		delay_ms = 5,
		kbit     = 7800,
	}

	adapt_bitrate(&v, bad, MAX, at)
	testing.expect_value(t, v.target_kbit, 6000)
	// Too soon to cut again.
	adapt_bitrate(&v, bad, MAX, later(at, time.Second))
	testing.expect_value(t, v.target_kbit, 6000)
	// Delay counts as much as loss; what reaches them (3000) goes too.
	adapt_bitrate(&v, {loss = 0, delay_ms = 300, kbit = 3000}, MAX, later(at, 2 * time.Second))
	testing.expect_value(t, v.target_kbit, 3000 * 3 / 4)
	// Never under an eighth.
	for i in 3 ..< 20 {
		adapt_bitrate(
			&v,
			{loss = 900, kbit = 100},
			MAX,
			later(at, time.Duration(i) * 2 * time.Second),
		)
	}
	testing.expect_value(t, v.target_kbit, MAX / ADAPT_FLOOR)

	// Good for long enough: up a fifth of what it was set to, each time.
	at = later(at, time.Minute)
	adapt_bitrate(&v, good, MAX, at)
	testing.expect_value(t, v.target_kbit, MAX / ADAPT_FLOOR)
	adapt_bitrate(&v, good, MAX, later(at, ADAPT_GOOD_FOR))
	testing.expect_value(t, v.target_kbit, MAX / ADAPT_FLOOR + MAX / 5)
	// In between (some loss, not much): as it is, and the good run starts again.
	adapt_bitrate(&v, {loss = 10, delay_ms = 5}, MAX, later(at, ADAPT_GOOD_FOR + time.Second))
	adapt_bitrate(&v, good, MAX, later(at, ADAPT_GOOD_FOR + 2 * time.Second))
	testing.expect_value(t, v.target_kbit, MAX / ADAPT_FLOOR + MAX / 5)
	for i in 1 ..= 10 {
		adapt_bitrate(
			&v,
			good,
			MAX,
			later(at, ADAPT_GOOD_FOR + 2 * time.Second + time.Duration(i) * ADAPT_GOOD_FOR),
		)
	}
	// Back to as set, which is 0.
	testing.expect_value(t, v.target_kbit, 0)
}

@(test)
test_viewer_codecs :: proc(t: ^testing.T) {
	c: Voice_Client
	users := []proto.User_Info {
		{num = 1, room = 7, flags = {.Sharing, .Decodes_HEVC, .Decodes_AV1}}, // us
		{num = 2, room = 7, flags = {.Decodes_HEVC, .Decodes_AV1}},
		{num = 3, room = 8}, // elsewhere, and too old to say
	}
	c.channels.have_state = true
	c.channels.state.your_user = 1
	c.channels.state.users = users
	testing.expect_value(t, viewer_codecs(&c), proto.Video_Codecs{.H264, .HEVC, .AV1})

	// A browser without HEVC joins.
	users[2] = {
		num   = 3,
		room  = 7,
		flags = {.Muted, .Decodes_AV1},
	}
	testing.expect_value(t, viewer_codecs(&c), proto.Video_Codecs{.H264, .AV1})

	// Then a client too old to say: H.264 is all it surely decodes.
	users[1].flags = {}
	testing.expect_value(t, viewer_codecs(&c), proto.Video_Codecs{.H264})

	// Out of the room, nobody's watching.
	users[0].room = 0
	testing.expect_value(t, viewer_codecs(&c), proto.Video_Codecs{.H264, .HEVC, .AV1})
}
