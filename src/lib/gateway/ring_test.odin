package gateway

import "core:sync"
import "core:testing"
import "core:thread"

// Tests of the Ring that a streamed transfer is shared through (files.odin):
// whoever releases it last frees it, and the side that waits on it is woken
// when its buffer comes or when the other side gives up. The transfers
// themselves are tested by server/gateway_test.odin.

@(test)
test_ring_refs :: proc(t: ^testing.T) {
	// Each holder releases it once. Freeing it early or not at all shows up as
	// a bad free or a leak.
	r := ring_make(100, 2)
	testing.expect_value(t, len(r.buf), RING_SIZE)
	testing.expect_value(t, r.size, u64(100))
	ring_release(r)
	ring_fail(r)
	testing.expect(t, r.failed)
	ring_release(r)
}

@(test)
test_ring_allocate :: proc(t: ^testing.T) {
	r := ring_make(100, 1, allocate = false)
	defer ring_release(r)
	testing.expect(t, r.buf == nil)
	sync.guard(&r.mutex)
	ring_allocate(r)
	testing.expect_value(t, len(r.buf), RING_SIZE)
	// A second time keeps the buffer it has.
	buf := raw_data(r.buf)
	ring_allocate(r)
	testing.expect(t, raw_data(r.buf) == buf)
}

// The HTTP thread of an upload waits for the ring's buffer, which only comes
// once the server has accepted the upload, or for the upload to fail.
@(private = "file")
Waiter :: struct {
	r:       ^Ring,
	got_buf: bool,
	failed:  bool,
	waiting: bool, // atomic
}

@(private = "file")
wait_for_ring :: proc(w: ^Waiter) {
	r := w.r
	sync.guard(&r.mutex)
	sync.atomic_store(&w.waiting, true)
	for !r.failed && r.buf == nil {
		sync.cond_wait(&r.cond, &r.mutex)
	}
	w.got_buf, w.failed = r.buf != nil, r.failed
}

@(test)
test_ring_wakes_the_waiter :: proc(t: ^testing.T) {
	for fail in ([]bool{false, true}) {
		w := Waiter {
			r = ring_make(100, 1, allocate = false),
		}
		th := thread.create_and_start_with_poly_data(&w, wait_for_ring)
		for !sync.atomic_load(&w.waiting) {
			thread.yield()
		}
		if fail {
			ring_fail(w.r)
		} else {
			sync.guard(&w.r.mutex)
			ring_allocate(w.r)
		}
		thread.join(th)
		thread.destroy(th)
		testing.expect_value(t, w.got_buf, !fail)
		testing.expect_value(t, w.failed, fail)
		ring_release(w.r)
	}
}
