package server

import "core:testing"
import "core:time"

// Tests of the loop's timing (loop_stats.odin).

@(test)
test_loop_bucket :: proc(t: ^testing.T) {
	testing.expect_value(t, loop_bucket(50 * time.Microsecond), 0)
	// A bound belongs to the bucket above it.
	testing.expect_value(t, loop_bucket(SLOW_TURN), 6)
	testing.expect_value(t, loop_bucket(50 * time.Millisecond), len(loop_buckets))
}

@(test)
test_loop_percentile :: proc(t: ^testing.T) {
	l := Loop_Stats {
		turns = 100,
	}
	l.buckets[0] = 98
	l.buckets[loop_bucket(15 * time.Millisecond)] = 1
	l.buckets[len(loop_buckets)] = 1
	testing.expect_value(t, loop_percentile(&l, 0.5), "under 100µs")
	testing.expect_value(t, loop_percentile(&l, 0.99), "under 20ms")
	testing.expect_value(t, loop_percentile(&l, 1), "over 40ms")
}

@(test)
test_loop_top_phases :: proc(t: ^testing.T) {
	phases: [Loop_Phase]time.Duration
	phases[.Stream] = 200 * time.Microsecond
	phases[.Commit] = time.Millisecond
	phases[.Packet] = 6 * time.Millisecond
	top := loop_top_phases(&phases, 7200 * time.Microsecond)
	testing.expect_value(t, len(top), 2)
	testing.expect_value(t, top[0], Loop_Phase.Packet)
	testing.expect_value(t, top[1], Loop_Phase.Commit)

	// A turn with nothing to it still has a phase to name.
	none: [Loop_Phase]time.Duration
	testing.expect_value(t, len(loop_top_phases(&none, 0)), 1)
}

@(test)
test_loop_turn_counted :: proc(t: ^testing.T) {
	s: Server
	loop_stats_open(&s)
	loop_turn_begin(&s)
	loop_mark(&s, .Packet)
	loop_mark(&s, .Commit)
	loop_turn_end(&s, packet = true)
	loop_turn_begin(&s)
	loop_turn_end(&s, packet = false)
	testing.expect_value(t, s.loop.turns, 2)
	testing.expect_value(t, s.loop.packets, 1)
	testing.expect(t, s.loop.longest >= 0)
	when ODIN_OS != .Windows {
		testing.expect(t, s.loop.has_cpu)
	}
}
