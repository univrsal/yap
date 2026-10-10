package server

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

/*
How long the loop's turns take, and where the time goes.

A turn is one packet (or none, when the wait runs out) and then every
sync pass and the commit (run_server). Each of those is a phase, and a
turn's time is split between them as it goes (loop_mark): reading the
clock is cheap enough to do that every time. How much of the turn the
thread was on the CPU is read once, at each end of it: wall time it
wasn't is time it was waiting, for the disk or for the system to give
it back the CPU, which a busy machine (or one running clients too, when
testing) does now and then for a few ms.

What it costs voice: a packet that comes during a long turn waits in
the socket until it's over, and so do the ones behind it. A client
plays a speaker with 20 ms more queued than the frame being played, or
more for one whose packets come unevenly (speaker_prefill in
client/audio/voice.odin), so a voice packet can be about VOICE_SLACK
late before anything is heard - less whatever the network adds. A turn
longer than SLOW_TURN is logged as info, and one longer than VOICE_SLACK
as a warning: those are the ones that can be heard, as a gap or as that
speaker being played later for a while.

Every LOOP_REPORT the log says how the turns went since the last time:
how many, how busy the loop was, how long they took, the longest one,
and which phases the time went to. At info if any were slow, else at
debug.
*/

// A turn longer than this is logged, with where its time went.
SLOW_TURN :: 5 * time.Millisecond
// About how late a voice packet can come before a client runs out of
// that speaker's audio (see above).
VOICE_SLACK :: 20 * time.Millisecond
// How often the log sums up the turns: ten minutes, or for a test run
// -define:YAP_LOOP_REPORT_SECONDS=10.
LOOP_REPORT :: #config(YAP_LOOP_REPORT_SECONDS, 600) * time.Second

Loop_Phase :: enum u8 {
	Packet,
	Reap,
	Auth,
	Stream,
	State,
	Transfers,
	Attachments,
	Files,
	Emoji,
	Profiles,
	Calls,
	Retention,
	Verify,
	Exercise,
	Memory,
	Commit,
}

// How turns are counted by how long they took: under each bound, the
// last one being everything longer.
@(rodata)
loop_buckets := [?]time.Duration {
	100 * time.Microsecond,
	250 * time.Microsecond,
	500 * time.Microsecond,
	time.Millisecond,
	2 * time.Millisecond,
	SLOW_TURN,
	10 * time.Millisecond,
	VOICE_SLACK,
	40 * time.Millisecond,
}

Loop_Stats :: struct {
	// This turn.
	started:          time.Tick,
	marked:           time.Tick, // where the last phase ended
	cpu_started:      time.Duration,
	phases:           [Loop_Phase]time.Duration,

	// Since the last report.
	since:            time.Tick,
	turns:            int,
	packets:          int,
	busy:             time.Duration,
	cpu:              time.Duration,
	has_cpu:          bool,
	buckets:          [len(loop_buckets) + 1]int,
	totals:           [Loop_Phase]time.Duration,
	longest:          time.Duration,
	// What the longest turn was handling, and its longest phase.
	longest_handling: proto.Message_Kind,
	longest_phase:    Loop_Phase,
}

loop_stats_open :: proc(s: ^Server) {
	s.loop.since = time.tick_now()
}

// loop_turn_begin starts timing a turn, once its packet (if any) is in.
loop_turn_begin :: proc(s: ^Server) {
	l := &s.loop
	l.started = time.tick_now()
	l.marked = l.started
	l.phases = {}
	l.cpu_started, _ = thread_cpu_time()
}

// loop_mark puts the time since the last mark down to `phase`.
loop_mark :: proc(s: ^Server, phase: Loop_Phase) {
	l := &s.loop
	now := time.tick_now()
	l.phases[phase] += time.tick_diff(l.marked, now)
	l.marked = now
}

// loop_turn_end counts the turn, says so if it was slow, and sums up the
// turns when it's time to.
loop_turn_end :: proc(s: ^Server, packet: bool) {
	l := &s.loop
	took := time.tick_diff(l.started, l.marked)
	cpu, has_cpu := thread_cpu_time()
	cpu -= l.cpu_started

	l.turns += 1
	l.packets += int(packet)
	l.busy += took
	l.cpu += cpu
	l.has_cpu = has_cpu
	l.buckets[loop_bucket(took)] += 1
	for t, phase in l.phases {
		l.totals[phase] += t
	}
	if took > l.longest {
		l.longest = took
		l.longest_handling = s.handling
		l.longest_phase = loop_top_phases(&l.phases, took)[0]
	}

	if took > SLOW_TURN {
		loop_slow(s, took, cpu, has_cpu)
	}
	if time.tick_since(l.since) >= LOOP_REPORT {
		loop_report(s)
	}
}

loop_bucket :: proc(took: time.Duration) -> int {
	for bound, i in loop_buckets {
		if took < bound {
			return i
		}
	}
	return len(loop_buckets)
}

// loop_top_phases is the phases that took at least a tenth of `total`,
// longest first; at least one.
loop_top_phases :: proc(phases: ^[Loop_Phase]time.Duration, total: time.Duration) -> []Loop_Phase {
	order := make([dynamic]Loop_Phase, 0, len(Loop_Phase), context.temp_allocator)
	for phase in Loop_Phase {
		append(&order, phase)
	}
	// Longest first; a sort proc couldn't see `phases`.
	for i in 1 ..< len(order) {
		for j := i; j > 0 && phases[order[j]] > phases[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	n := 1
	for n < len(order) && phases[order[n]] * 10 >= total && phases[order[n]] > 0 {
		n += 1
	}
	return order[:n]
}

// loop_slow says what a slow turn was doing.
@(private = "file")
loop_slow :: proc(s: ^Server, took, cpu: time.Duration, has_cpu: bool) {
	l := &s.loop
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "a turn of the loop took %.1f ms", time.duration_milliseconds(took))
	if has_cpu {
		fmt.sbprintf(&b, " (%.1f ms of it on the CPU)", time.duration_milliseconds(cpu))
	}
	if s.handling != {} {
		fmt.sbprintf(&b, ", handling %v", s.handling)
	}
	strings.write_string(&b, ":")
	for phase, i in loop_top_phases(&l.phases, took) {
		fmt.sbprintf(
			&b,
			"%s %v %.1f ms",
			"" if i == 0 else ",",
			phase,
			time.duration_milliseconds(l.phases[phase]),
		)
	}
	if took > VOICE_SLACK {
		log.warn(strings.to_string(b))
	} else {
		log.info(strings.to_string(b))
	}
}

// loop_report sums up the turns since the last report, and starts
// counting again.
@(private = "file")
loop_report :: proc(s: ^Server) {
	l := &s.loop
	now := time.tick_now()
	window := time.tick_diff(l.since, now)
	if l.turns == 0 || window <= 0 {
		l.since = now
		return
	}
	b := strings.builder_make(context.temp_allocator)
	if window < 2 * time.Minute {
		fmt.sbprintf(&b, "loop, last %.0f s:", time.duration_seconds(window))
	} else {
		fmt.sbprintf(&b, "loop, last %.0f min:", time.duration_minutes(window))
	}
	fmt.sbprintf(
		&b,
		" %d turns, %d packets, busy %.2f%%",
		l.turns,
		l.packets,
		100 * f64(l.busy) / f64(window),
	)
	if l.has_cpu {
		fmt.sbprintf(&b, " (on the CPU %.2f%%)", 100 * f64(l.cpu) / f64(window))
	}
	fmt.sbprintf(
		&b,
		"; median %s, 99%% %s, longest %.1f ms (%v",
		loop_percentile(l, 0.5),
		loop_percentile(l, 0.99),
		time.duration_milliseconds(l.longest),
		l.longest_phase,
	)
	if l.longest_handling != {} {
		fmt.sbprintf(&b, ", %v", l.longest_handling)
	}
	slow, audible := 0, 0
	for n, i in l.buckets {
		if i > 0 && loop_buckets[i - 1] >= SLOW_TURN {
			slow += n
		}
		if i > 0 && loop_buckets[i - 1] >= VOICE_SLACK {
			audible += n
		}
	}
	fmt.sbprintf(
		&b,
		"); over %v: %d, over %v: %d; time went to:",
		SLOW_TURN,
		slow,
		VOICE_SLACK,
		audible,
	)
	for phase, i in loop_top_phases(&l.totals, l.busy) {
		fmt.sbprintf(
			&b,
			"%s %v %.0f%%",
			"" if i == 0 else ",",
			phase,
			100 * f64(l.totals[phase]) / f64(l.busy),
		)
	}
<<<<<<< HEAD
	if slow > 0 {
		log.info(strings.to_string(b))
	} else {
		log.debug(strings.to_string(b))
	}
=======
	log.info(strings.to_string(b))
>>>>>>> loop-timing
	l^ = {
		since = now,
	}
}

// loop_percentile is under which bucket's bound the given share of the
// turns took, as text.
loop_percentile :: proc(l: ^Loop_Stats, share: f64) -> string {
	want := int(f64(l.turns) * share + 0.5)
	seen := 0
	for n, i in l.buckets {
		seen += n
		if seen >= want && seen > 0 {
			if i == len(loop_buckets) {
				return fmt.tprintf("over %v", loop_buckets[i - 1])
			}
			return fmt.tprintf("under %v", loop_buckets[i])
		}
	}
	return "-"
}
