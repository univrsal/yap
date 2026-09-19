package client

import "core:sync"
import "core:testing"
import "core:thread"

@(test)
test_ring_basics :: proc(t: ^testing.T) {
	r: Ring
	ring_init(&r, 5) // rounds up to 8
	defer ring_destroy(&r)
	testing.expect_value(t, len(r.buf), 8)

	testing.expect_value(t, ring_write(&r, {1, 2, 3, 4, 5, 6}), 6)
	testing.expect_value(t, ring_write(&r, {7, 8, 9, 10}), 2) // only 2 fit
	testing.expect_value(t, ring_available(&r), 8)

	out: [5]f32
	testing.expect_value(t, ring_read(&r, out[:]), 5)
	testing.expect_value(t, out, [5]f32{1, 2, 3, 4, 5})
	testing.expect_value(t, ring_skip(&r, 1), 1)

	// Wraps around the end of the buffer.
	testing.expect_value(t, ring_write(&r, {11, 12, 13, 14}), 4)
	got: [8]f32
	testing.expect_value(t, ring_read(&r, got[:]), 6)
	testing.expect_value(
		t,
		[6]f32{got[0], got[1], got[2], got[3], got[4], got[5]},
		[6]f32{7, 8, 11, 12, 13, 14},
	)
	testing.expect_value(t, ring_available(&r), 0)
}

@(test)
test_ring_threads :: proc(t: ^testing.T) {
	// One producer and one consumer hammering the ring; every sample must
	// arrive exactly once, in order.
	Shared :: struct {
		ring: Ring,
		done: bool,
	}
	s: Shared
	ring_init(&s.ring, 64)
	defer ring_destroy(&s.ring)

	TOTAL :: 200_000
	producer := thread.create_and_start_with_poly_data(&s, proc(s: ^Shared) {
		next := 0
		chunk: [13]f32
		for next < TOTAL {
			n := min(len(chunk), TOTAL - next)
			for i in 0 ..< n {
				chunk[i] = f32(next + i)
			}
			next += ring_write(&s.ring, chunk[:n])
		}
		sync.atomic_store(&s.done, true)
	})

	expected := 0
	ok := true
	buf: [7]f32
	for expected < TOTAL {
		n := ring_read(&s.ring, buf[:])
		for v in buf[:n] {
			if v != f32(expected) {
				ok = false
			}
			expected += 1
		}
	}
	thread.join(producer)
	thread.destroy(producer)
	testing.expect(t, ok, "samples arrived out of order or corrupted")
	testing.expect_value(t, expected, TOTAL)
}
