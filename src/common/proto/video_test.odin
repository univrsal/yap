#+build !wasi
package proto

import "core:testing"
import "core:time"

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
			{
				frame = num,
				ts = num * 100,
				index = i,
				count = count,
				key = key,
				data = data[start:end],
			},
		)
		sharer, f, ok := decode_video_down(msg)
		assert(ok && sharer == 9)
		out[i] = f
	}
	return out
}

// feed gives a window every fragment at `now` and returns the last
// frame that came out.
@(private = "file")
feed :: proc(
	w: ^Video_Window,
	fs: []Video_Fragment,
	now: time.Tick = {},
) -> (
	frame: Video_Frame,
	complete: bool,
) {
	for f in fs {
		video_window_add(w, f, now)
		for {
			got := video_window_pop(w) or_break
			frame, complete = got, true
		}
	}
	return
}

// later is `ms` milliseconds after `t`.
@(private = "file")
later :: proc(t: time.Tick, ms: int) -> time.Tick {
	return time.tick_add(t, time.Duration(ms) * time.Millisecond)
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
test_window_waits_for_key :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)

	// A delta before any keyframe has nothing to decode against.
	_, ok := feed(w, fragments(1, false, make_frame(500)))
	testing.expect(t, !ok)
	testing.expect(t, w.broken)

	key := make_frame(2 * VIDEO_FRAGMENT_SIZE + 5)
	frame: Video_Frame
	frame, ok = feed(w, fragments(2, true, key))
	testing.expect(t, ok)
	testing.expect(t, !w.broken)
	testing.expect(t, frame.key)
	testing.expect_value(t, frame.ts, 200)
	testing.expect_value(t, string(frame.data), string(key))

	delta := make_frame(40)
	frame, ok = feed(w, fragments(3, false, delta))
	testing.expect(t, ok)
	testing.expect_value(t, string(frame.data), string(delta))
}

@(test)
test_window_out_of_order :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)
	_, ok := feed(w, fragments(1, true, make_frame(100)))
	testing.expect(t, ok)

	// Frame 3 comes before the end of frame 2: both come out, in order.
	two := make_frame(3 * VIDEO_FRAGMENT_SIZE)
	three := make_frame(50)
	f2 := fragments(2, false, two)
	f2[0], f2[2] = f2[2], f2[0]
	_, ok = feed(w, f2[:2])
	testing.expect(t, !ok)
	video_window_add(w, fragments(3, false, three)[0], {})
	_, ok = video_window_pop(w)
	testing.expect(t, !ok)
	video_window_add(w, f2[2], {})
	frame: Video_Frame
	frame, ok = video_window_pop(w)
	testing.expect(t, ok)
	testing.expect_value(t, frame.frame, 2)
	testing.expect_value(t, string(frame.data), string(two))
	frame, ok = video_window_pop(w)
	testing.expect(t, ok)
	testing.expect_value(t, frame.frame, 3)
	testing.expect(t, !w.broken)

	// A repeat of a finished frame is ignored.
	video_window_add(w, f2[1], {})
	_, ok = video_window_pop(w)
	testing.expect(t, !ok)
}

@(test)
test_window_largest_frame :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)
	data := make_frame(MAX_VIDEO_FRAGMENTS * VIDEO_FRAGMENT_SIZE)
	frame, ok := feed(w, fragments(1, true, data))
	testing.expect(t, ok)
	testing.expect_value(t, len(frame.data), len(data))
}

@(test)
test_window_nacks_and_recovers :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)
	now := time.tick_now()
	_, ok := feed(w, fragments(1, true, make_frame(100)), now)
	testing.expect(t, ok)

	// Frame 2 loses fragments 1 and 3 of 5; frame 3 comes.
	two := make_frame(5 * VIDEO_FRAGMENT_SIZE)
	f2 := fragments(2, false, two)
	video_window_add(w, f2[0], now)
	video_window_add(w, f2[2], now)
	video_window_add(w, f2[4], now)
	_, ok = feed(w, fragments(3, false, make_frame(10)), now)
	testing.expect(t, !ok)

	// Not yet: it may be reordering.
	testing.expect_value(t, len(video_window_nacks(w, later(now, 1), true)), 0)
	nacks := video_window_nacks(w, later(now, 15), true)
	testing.expect_value(t, len(nacks), 1)
	if len(nacks) == 1 {
		testing.expect_value(t, nacks[0].frame, 2)
		testing.expect_value(t, nacks[0].first, 1)
		testing.expect_value(t, nacks[0].missing, 0b101)
	}
	// Asked once; not again until NACK_RETRY.
	testing.expect_value(t, len(video_window_nacks(w, later(now, 30), true)), 0)

	// What was asked for comes: both frames out, nothing broken.
	video_window_add(w, f2[1], later(now, 40))
	video_window_add(w, f2[3], later(now, 40))
	frame: Video_Frame
	frame, ok = video_window_pop(w)
	testing.expect(t, ok)
	testing.expect_value(t, string(frame.data), string(two))
	frame, ok = video_window_pop(w)
	testing.expect(t, ok)
	testing.expect_value(t, frame.frame, 3)
	testing.expect(t, !w.broken)
	testing.expect_value(t, w.recovered, 1)
}

@(test)
test_window_gives_up :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)
	now := time.tick_now()
	_, ok := feed(w, fragments(1, true, make_frame(100)), now)
	testing.expect(t, ok)

	// Frame 2's last fragment never comes, nor anything after: once
	// TAIL_WAIT has passed it's missed, asked for twice, then given up.
	f2 := fragments(2, false, make_frame(2 * VIDEO_FRAGMENT_SIZE))
	video_window_add(w, f2[0], now)
	testing.expect_value(t, len(video_window_nacks(w, later(now, 5), true)), 0)
	nacks := video_window_nacks(w, later(now, 25), true)
	testing.expect_value(t, len(nacks), 0) // seen missing just now
	nacks = video_window_nacks(w, later(now, 40), true)
	testing.expect_value(t, len(nacks), 1)
	nacks = video_window_nacks(w, later(now, 60), true)
	testing.expect_value(t, len(nacks), 0)
	nacks = video_window_nacks(w, later(now, 130), true)
	testing.expect_value(t, len(nacks), 1)
	nacks = video_window_nacks(w, later(now, 220), true)
	testing.expect_value(t, len(nacks), 0)
	_, ok = video_window_pop(w)
	testing.expect(t, !ok)
	testing.expect(t, w.broken)
	testing.expect_value(t, w.given_up, 1)

	// Deltas don't get through until a keyframe.
	_, ok = feed(w, fragments(3, false, make_frame(10)), later(now, 230))
	testing.expect(t, !ok)
	_, ok = feed(w, fragments(4, true, make_frame(10)), later(now, 240))
	testing.expect(t, ok)
	testing.expect(t, !w.broken)
}

@(test)
test_window_skipped_frame :: proc(t: ^testing.T) {
	w := new(Video_Window)
	defer free(w)
	defer video_window_destroy(w)
	video_window_reset(w)
	now := time.tick_now()
	_, ok := feed(w, fragments(1, true, make_frame(100)), now)
	testing.expect(t, ok)

	// Frame 2 doesn't come at all: it's asked for from its start.
	_, ok = feed(w, fragments(3, false, make_frame(10)), now)
	testing.expect(t, !ok)
	testing.expect_value(t, len(video_window_nacks(w, later(now, 1), true)), 0)
	nacks := video_window_nacks(w, later(now, 15), true)
	testing.expect_value(t, len(nacks), 1)
	if len(nacks) == 1 {
		testing.expect_value(t, nacks[0].frame, 2)
		testing.expect_value(t, nacks[0].first, 0)
	}
	// It comes after all.
	_, ok = feed(w, fragments(2, false, make_frame(30)), later(now, 30))
	testing.expect(t, ok)
	testing.expect(t, !w.broken)

	// Without anyone to ask, it's given up on once it's surely lost.
	_, ok = feed(w, fragments(5, false, make_frame(10)), later(now, 40))
	testing.expect(t, !ok)
	testing.expect_value(t, len(video_window_nacks(w, later(now, 41), false)), 0)
	_, ok = video_window_pop(w)
	testing.expect(t, !ok)
	testing.expect(t, !w.broken)
	testing.expect_value(t, len(video_window_nacks(w, later(now, 55), false)), 0)
	_, ok = video_window_pop(w)
	testing.expect(t, !ok)
	testing.expect(t, w.broken)

	// So far ahead that frames fall out of the window: broken as well.
	video_window_reset(w)
	_, ok = feed(w, fragments(10, true, make_frame(10)), now)
	testing.expect(t, ok)
	_, ok = feed(w, fragments(10 + VIDEO_WINDOW + 3, false, make_frame(10)), now)
	testing.expect(t, !ok)
	testing.expect(t, w.broken)
}

@(test)
test_nack_roundtrip :: proc(t: ^testing.T) {
	buf: [NACK_SIZE]u8
	msg := encode_nack(&buf, 9, {frame = 77, first = 128, missing = 0xdead_beef})
	sharer, n, ok := decode_nack(msg)
	testing.expect(t, ok)
	testing.expect_value(t, sharer, 9)
	testing.expect_value(t, n.frame, 77)
	testing.expect_value(t, n.first, 128)
	testing.expect_value(t, n.missing, 0xdead_beef)
	_, _, ok = decode_nack(msg[:NACK_SIZE - 1])
	testing.expect(t, !ok)
}

@(test)
test_video_report :: proc(t: ^testing.T) {
	buf: [REPORT_SIZE]u8
	msg := encode_report_up(&buf, 7, {loss = 12, delay_ms = 40, kbit = 6000})
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok)
	testing.expect_value(t, kind, Message_Kind.Report)
	sharer, r, ok := decode_report_up(msg)
	testing.expect(t, ok)
	testing.expect_value(t, sharer, 7)
	testing.expect_value(t, r, Video_Report{loss = 12, delay_ms = 40, kbit = 6000})
	// Out of range: held to what fits.
	_, r, _ = decode_report_up(encode_report_up(&buf, 7, {loss = 5000, delay_ms = -3}))
	testing.expect_value(t, r.loss, 1000)
	testing.expect_value(t, r.delay_ms, 0)
	_, _, ok = decode_report_up(msg[:REPORT_SIZE - 1])
	testing.expect(t, !ok)

	down := Video_Reports {
		viewers = 4,
		left_out = 1,
		worst = {loss = 30, delay_ms = 120, kbit = 4500},
	}
	got, down_ok := decode_report_down(encode_report_down(&buf, down))
	testing.expect(t, down_ok)
	testing.expect_value(t, got, down)
}

@(test)
test_summarize_reports :: proc(t: ^testing.T) {
	testing.expect_value(t, summarize_reports(nil), Video_Reports{})

	// Two: the worst of each, whoever it's from.
	two := []Video_Report {
		{loss = 10, delay_ms = 80, kbit = 6000},
		{loss = 30, delay_ms = 20, kbit = 7000},
	}
	s := summarize_reports(two)
	testing.expect_value(
		t,
		s,
		Video_Reports{viewers = 2, worst = {loss = 30, delay_ms = 80, kbit = 6000}},
	)

	// One of three far behind the others: left out.
	three := []Video_Report {
		{loss = 5, delay_ms = 10, kbit = 6000},
		{loss = 200, delay_ms = 400, kbit = 900},
		{loss = 8, delay_ms = 30, kbit = 5800},
	}
	s = summarize_reports(three)
	testing.expect_value(
		t,
		s,
		Video_Reports{viewers = 3, left_out = 1, worst = {loss = 8, delay_ms = 30, kbit = 5800}},
	)

	// Not far behind: counted.
	close := []Video_Report {
		{loss = 5, delay_ms = 10, kbit = 6000},
		{loss = 40, delay_ms = 50, kbit = 5000},
		{loss = 8, delay_ms = 30, kbit = 5800},
	}
	s = summarize_reports(close)
	testing.expect_value(t, s.left_out, 0)
	testing.expect_value(t, s.worst.loss, 40)
}
