#+build !wasi
package proto

import "core:testing"
import "core:time"

// A pseudo-random number generator of the test's own, so a failure
// happens again the next time it's run.
@(private = "file")
Rng :: distinct u64

@(private = "file")
rng_next :: proc(r: ^Rng, n: int) -> int {
	r^ = r^ * 6364136223846793005 + 1442695040888963407
	return int((u64(r^) >> 33) % u64(n))
}

// One direction of a connection that loses, repeats and reorders what
// it carries. Packets are in the temp allocator.
@(private = "file")
Link :: struct {
	packets: [dynamic][]u8,
	loss:    int, // percent
	repeats: int, // percent
}

@(private = "file")
link_put :: proc(l: ^Link, r: ^Rng, msg: []u8) {
	copies := 1
	if rng_next(r, 100) < l.loss {
		copies = 0
	} else if rng_next(r, 100) < l.repeats {
		copies = 2
	}
	for _ in 0 ..< copies {
		p := make([]u8, len(msg), context.temp_allocator)
		copy(p, msg)
		append(&l.packets, p)
	}
}

// link_deliver hands everything in the link to `to`, in any order.
@(private = "file")
link_deliver :: proc(t: ^testing.T, l: ^Link, r: ^Rng, to: ^Stream) {
	for len(l.packets) > 0 {
		i := rng_next(r, len(l.packets))
		p := l.packets[i]
		unordered_remove(&l.packets, i)
		kind, ok := message_kind(p)
		testing.expect(t, ok)
		#partial switch kind {
		case .Stream:
			testing.expect_value(t, stream_receive(to, p), Stream_Error.None)
		case .Stream_Ack:
			stream_acked(to, p)
		case:
			testing.fail(t)
		}
	}
}

// test_message is message `i` of a run: its size and its bytes both
// follow from the number, so the receiver can tell what it should be.
@(private = "file")
test_message :: proc(i: int, sizes: []int) -> []u8 {
	m := make([]u8, sizes[i % len(sizes)], context.temp_allocator)
	for &b, j in m {
		b = u8(i * 31 + j * 7 + j / 251)
	}
	return m
}

@(private = "file")
same :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

// run_pair sends `count` messages each way through links like that and
// expects every one to arrive once, in order.
@(private = "file")
run_pair :: proc(t: ^testing.T, loss, repeats: int, count: int, sizes: []int, seed: Rng) {
	a, b: Stream
	defer stream_destroy(&a)
	defer stream_destroy(&b)
	ab := Link {
		packets = make([dynamic][]u8, context.temp_allocator),
		loss    = loss,
		repeats = repeats,
	}
	ba := ab
	ba.packets = make([dynamic][]u8, context.temp_allocator)
	r := seed

	ends := [2]^Stream{&a, &b}
	links := [2]^Link{&ab, &ba} // what each end sends into
	queued, got: [2]int
	now := time.tick_now()
	buf: [MAX_PAYLOAD_SIZE]u8

	for step := 0; step < 20000 && (got[0] < count || got[1] < count); step += 1 {
		now = time.tick_add(now, 20 * time.Millisecond)
		for s, e in ends {
			// A few more messages now and then, as an application would.
			for queued[e] < count && rng_next(&r, 4) == 0 {
				testing.expect(t, stream_send(s, test_message(queued[e], sizes)))
				queued[e] += 1
			}
			for {
				msg, ok := stream_next_frame(s, now, STREAM_RESEND, buf[:])
				if !ok {
					break
				}
				link_put(links[e], &r, msg)
			}
		}
		for s, e in ends {
			link_deliver(t, links[1 - e], &r, s)
			for {
				m, ok := stream_next(s)
				if !ok {
					break
				}
				// What the other end queued, in the order it did.
				if !testing.expect(t, same(m, test_message(got[e], sizes))) {
					return
				}
				got[e] += 1
			}
			ack_buf: [STREAM_ACK_SIZE]u8
			if ack, ok := stream_ack(s, &ack_buf); ok {
				link_put(links[e], &r, ack)
			}
		}
	}
	testing.expect_value(t, got[0], count)
	testing.expect_value(t, got[1], count)

	// The last acknowledgements may have been lost; a few quiet rounds
	// of resending settle it.
	for step := 0; step < 2000 && !(stream_idle(&a) && stream_idle(&b)); step += 1 {
		now = time.tick_add(now, 20 * time.Millisecond)
		for s, e in ends {
			for {
				msg, ok := stream_next_frame(s, now, STREAM_RESEND, buf[:])
				if !ok {
					break
				}
				link_put(links[e], &r, msg)
			}
		}
		for s, e in ends {
			link_deliver(t, links[1 - e], &r, s)
			_, more := stream_next(s)
			testing.expect(t, !more)
			ack_buf: [STREAM_ACK_SIZE]u8
			if ack, ok := stream_ack(s, &ack_buf); ok {
				link_put(links[e], &r, ack)
			}
		}
	}
	testing.expect(t, stream_idle(&a) && stream_idle(&b))
}

@(test)
test_stream_clean :: proc(t: ^testing.T) {
	run_pair(t, 0, 0, 200, {1, 40, 500}, 1)
}

@(test)
test_stream_lossy :: proc(t: ^testing.T) {
	// Lost, repeated and out of order, with messages of one byte, of
	// exactly a frame, of a byte more, and of many frames.
	sizes := []int{1, 40, STREAM_FRAME_DATA, STREAM_FRAME_DATA + 1, 5000, 300}
	for seed in 1 ..= 5 {
		run_pair(t, 30, 20, 300, sizes, Rng(seed))
	}
}

@(test)
test_stream_largest :: proc(t: ^testing.T) {
	// More frames than the window holds, so it has to move along.
	run_pair(t, 30, 10, 6, {STREAM_MAX_MESSAGE, 3, STREAM_MAX_MESSAGE - 1}, 7)
}

@(test)
test_stream_window :: proc(t: ^testing.T) {
	s: Stream
	defer stream_destroy(&s)
	big := make([]u8, STREAM_MAX_MESSAGE, context.temp_allocator)
	testing.expect(t, stream_send(&s, big))
	testing.expect(t, stream_send(&s, big))

	// With nothing acknowledged, a window's worth goes out and no more.
	now := time.tick_now()
	buf: [MAX_PAYLOAD_SIZE]u8
	sent := 0
	for {
		if _, ok := stream_next_frame(&s, now, STREAM_RESEND, buf[:]); !ok {
			break
		}
		sent += 1
	}
	testing.expect_value(t, sent, STREAM_WINDOW)

	// Nothing is resent before its time, and all of it once it's up.
	_, early := stream_next_frame(&s, time.tick_add(now, STREAM_RESEND / 2), STREAM_RESEND, buf[:])
	testing.expect(t, !early)
	later := time.tick_add(now, STREAM_RESEND)
	resent := 0
	for {
		if _, ok := stream_next_frame(&s, later, STREAM_RESEND, buf[:]); !ok {
			break
		}
		resent += 1
	}
	testing.expect_value(t, resent, STREAM_WINDOW)
	// The second wait is twice the first.
	_, again := stream_next_frame(&s, time.tick_add(later, STREAM_RESEND), STREAM_RESEND, buf[:])
	testing.expect(t, !again)

	// Acknowledging ten lets ten more out.
	ack_buf: [STREAM_ACK_SIZE]u8
	stream_acked(&s, encode_stream_ack(&ack_buf, 10, 0))
	sent = 0
	for {
		if _, ok := stream_next_frame(&s, later, STREAM_RESEND, buf[:]); !ok {
			break
		}
		sent += 1
	}
	testing.expect_value(t, sent, 10)

	// An acknowledgement for frames never sent changes nothing.
	stream_acked(&s, encode_stream_ack(&ack_buf, 5000, 0))
	_, more := stream_next_frame(&s, later, STREAM_RESEND, buf[:])
	testing.expect(t, !more)
}

@(test)
test_stream_skipped :: proc(t: ^testing.T) {
	s: Stream
	defer stream_destroy(&s)
	for i in 0 ..< 4 {
		testing.expect(t, stream_send(&s, []u8{u8(i)}))
	}
	now := time.tick_now()
	buf: [MAX_PAYLOAD_SIZE]u8
	for _ in 0 ..< 4 {
		_, ok := stream_next_frame(&s, now, STREAM_RESEND, buf[:])
		testing.expect(t, ok)
	}

	// Frames 1 and 3 arrived, 0 and 2 didn't: those two go again at
	// once, and only those.
	ack_buf: [STREAM_ACK_SIZE]u8
	stream_acked(&s, encode_stream_ack(&ack_buf, 0, 0b101))
	for want in ([]u32{0, 2}) {
		msg, ok := stream_next_frame(&s, now, STREAM_RESEND, buf[:])
		testing.expect(t, ok)
		seq, _, _ := decode_stream(msg)
		testing.expect_value(t, seq, want)
	}
	_, more := stream_next_frame(&s, now, STREAM_RESEND, buf[:])
	testing.expect(t, !more)

	// The same news again doesn't hurry them a second time.
	stream_acked(&s, encode_stream_ack(&ack_buf, 0, 0b101))
	_, more = stream_next_frame(&s, now, STREAM_RESEND, buf[:])
	testing.expect(t, !more)

	stream_acked(&s, encode_stream_ack(&ack_buf, 4, 0))
	testing.expect(t, stream_idle(&s))
}

@(test)
test_stream_limits :: proc(t: ^testing.T) {
	s: Stream
	defer stream_destroy(&s)
	s.max_queue = 1000

	testing.expect(t, !stream_send(&s, nil))
	testing.expect(t, !stream_send(&s, make([]u8, STREAM_MAX_MESSAGE + 1, context.temp_allocator)))
	chunk := make([]u8, 400, context.temp_allocator)
	testing.expect(t, stream_send(&s, chunk))
	testing.expect(t, stream_send(&s, chunk))
	// The third would take the queue past its limit.
	testing.expect(t, !stream_send(&s, chunk))

	// What has gone out as frames no longer counts against it.
	buf: [MAX_PAYLOAD_SIZE]u8
	_, ok := stream_next_frame(&s, time.tick_now(), STREAM_RESEND, buf[:])
	testing.expect(t, ok)
	testing.expect(t, stream_send(&s, chunk))

	stream_reset(&s)
	testing.expect(t, stream_idle(&s))
	testing.expect_value(t, s.max_queue, 1000)
}

@(test)
test_stream_too_large :: proc(t: ^testing.T) {
	// A message that never ends: refused once it's longer than any may be.
	s: Stream
	defer stream_destroy(&s)
	data: [STREAM_FRAME_DATA]u8
	buf: [MAX_PAYLOAD_SIZE]u8
	frames := STREAM_MAX_MESSAGE / STREAM_FRAME_DATA
	for seq in 0 ..< frames {
		err := stream_receive(&s, encode_stream(buf[:], u32(seq), true, data[:]))
		testing.expect_value(t, err, Stream_Error.None)
	}
	err := stream_receive(&s, encode_stream(buf[:], u32(frames), true, data[:]))
	testing.expect_value(t, err, Stream_Error.Too_Large)
}

@(test)
test_stream_messages :: proc(t: ^testing.T) {
	buf: [MAX_PAYLOAD_SIZE]u8
	data := [3]u8{1, 2, 3}
	msg := encode_stream(buf[:], 0xdeadbeef, true, data[:])
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .Stream)
	seq, more, got := decode_stream(msg)
	testing.expect_value(t, seq, 0xdeadbeef)
	testing.expect(t, more)
	testing.expect(t, same(got, data[:]))
	// A frame with nothing in it isn't one.
	_, ok = message_kind(msg[:STREAM_HEADER_SIZE])
	testing.expect(t, !ok)

	// The longest frame is as long as a payload may be.
	full: [STREAM_FRAME_DATA]u8
	testing.expect_value(t, len(encode_stream(buf[:], 1, false, full[:])), MAX_PAYLOAD_SIZE)

	ack_buf: [STREAM_ACK_SIZE]u8
	ack := encode_stream_ack(&ack_buf, 17, 0x8000000000000001)
	kind, ok = message_kind(ack)
	testing.expect(t, ok && kind == .Stream_Ack)
	next, mask := decode_stream_ack(ack)
	testing.expect_value(t, next, 17)
	testing.expect_value(t, mask, 0x8000000000000001)
}
