package client

import "core:sync"

/*
Single-producer, single-consumer ring of samples, safe without locks
between exactly one writing thread and one reading thread. It connects
the audio device callbacks (which must never block) to the network
thread: capture callback -> network thread, network thread -> playback
callback.

Positions are running totals of samples written/read; the capacity is a
power of two so they can be masked into the buffer.
*/
Ring :: struct {
	buf:   []f32,
	mask:  u64,
	write: u64, // total written; only the producer stores it
	read:  u64, // total read; only the consumer stores it
}

ring_init :: proc(r: ^Ring, min_capacity: int) {
	capacity := 1
	for capacity < min_capacity {
		capacity *= 2
	}
	r.buf = make([]f32, capacity)
	r.mask = u64(capacity - 1)
	r.write, r.read = 0, 0
}

ring_destroy :: proc(r: ^Ring) {
	delete(r.buf)
	r.buf = nil
}

// ring_available is how many samples can be read right now.
ring_available :: proc "contextless" (r: ^Ring) -> int {
	return int(
		sync.atomic_load_explicit(&r.write, .Acquire) -
		sync.atomic_load_explicit(&r.read, .Acquire),
	)
}

// ring_write (producer) copies in as much of `samples` as fits and returns
// how many were written; the rest is dropped.
ring_write :: proc "contextless" (r: ^Ring, samples: []f32) -> int {
	w := sync.atomic_load_explicit(&r.write, .Relaxed)
	rd := sync.atomic_load_explicit(&r.read, .Acquire)
	n := min(len(samples), len(r.buf) - int(w - rd))
	for i in 0 ..< n {
		r.buf[(w + u64(i)) & r.mask] = samples[i]
	}
	sync.atomic_store_explicit(&r.write, w + u64(n), .Release)
	return n
}

// ring_read (consumer) fills `out` from the ring and returns how many
// samples it got.
ring_read :: proc "contextless" (r: ^Ring, out: []f32) -> int {
	rd := sync.atomic_load_explicit(&r.read, .Relaxed)
	w := sync.atomic_load_explicit(&r.write, .Acquire)
	n := min(len(out), int(w - rd))
	for i in 0 ..< n {
		out[i] = r.buf[(rd + u64(i)) & r.mask]
	}
	sync.atomic_store_explicit(&r.read, rd + u64(n), .Release)
	return n
}

// ring_skip (consumer) discards up to n samples.
ring_skip :: proc "contextless" (r: ^Ring, n: int) -> int {
	rd := sync.atomic_load_explicit(&r.read, .Relaxed)
	w := sync.atomic_load_explicit(&r.write, .Acquire)
	k := min(n, int(w - rd))
	sync.atomic_store_explicit(&r.read, rd + u64(k), .Release)
	return k
}
