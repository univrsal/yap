package server

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

// Timing of the server loop's turns, and where the time goes.
//
// A turn consists of handling one packet (or none, if the wait times out),
// followed by every sync pass and the commit (see run_server). Each of
// these is a phase, and the turn's time is divided between the phases as it
// progresses (see loop_mark). Reading the clock is cheap enough to do this
// every time. CPU time is only read once at the start and once at the end
// of a turn. Any wall time that wasn't CPU time was spent waiting, either
// for the disk or for the system to give the CPU back. A busy machine (or
// one that is also running clients, as in tests) does this now and then for
// a few ms.
//
// A long turn affects voice: a packet that arrives during it waits in the
// socket until the turn is over, and so do the packets behind it. A client
// plays a speaker with 20 ms more audio queued than the frame being played,
// or more if that speaker's packets arrive unevenly (see speaker_prefill in
// client/audio/voice.odin). So a voice packet can be about VOICE_SLACK
// late before anything is audible, minus whatever delay the network adds.
// A turn longer than SLOW_TURN is logged as info, and one longer than
// VOICE_SLACK is logged as a warning, because those can be heard as a gap
// or as that speaker being played later for a while.
//
// Every LOOP_REPORT, the log summarizes the turns since the last report:
// how many there were, how busy the loop was, how long they took, the
// longest one, and which phases took the most time. The summary is logged
// at info level if any turn was slow, and at debug level otherwise.

// Turns longer than this are logged together with where their time went.
SLOW_TURN :: 5 * time.Millisecond
// Roughly how late a voice packet can arrive before a client runs out of
// audio for that speaker (see above).
VOICE_SLACK :: 20 * time.Millisecond
// How often the turns are summarized in the log: every ten minutes, or
// for a test run, e.g. -define:YAP_LOOP_REPORT_SECONDS=10.
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
	Digest,
	Push,
	Media,
	Exercise,
	Memory,
	Commit,
}

// The bounds of the buckets that turns are counted in by duration. A turn
// goes into the first bucket whose bound it is under, and the last bucket
// holds everything longer.
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
	// The current turn.
	started:          time.Tick,
	marked:           time.Tick, // when the last phase ended
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

// loop_turn_begin starts timing a turn once its packet (if any) has arrived.
loop_turn_begin :: proc(s: ^Server) {
	l := &s.loop
	l.started = time.tick_now()
	l.marked = l.started
	l.phases = {}
	l.cpu_started, _ = thread_cpu_time()
}

// loop_mark attributes the time since the last mark to `phase`.
loop_mark :: proc(s: ^Server, phase: Loop_Phase) {
	l := &s.loop
	now := time.tick_now()
	l.phases[phase] += time.tick_diff(l.marked, now)
	l.marked = now
}

// loop_turn_end counts the turn, logs it if it was slow, and logs a summary
// of the turns when it is time for one.
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

// loop_top_phases returns the phases that took at least a tenth of `total`,
// longest first. It always returns at least one phase.
loop_top_phases :: proc(phases: ^[Loop_Phase]time.Duration, total: time.Duration) -> []Loop_Phase {
	order := make([dynamic]Loop_Phase, 0, len(Loop_Phase), context.temp_allocator)
	for phase in Loop_Phase {
		append(&order, phase)
	}
	// Sort longest first. This is done by hand because a sort proc couldn't
	// see `phases`.
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

// loop_slow logs what a slow turn was doing.
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

// loop_report logs a summary of the turns since the last report and then
// starts counting again.
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
	if slow > 0 {
		log.info(strings.to_string(b))
	} else {
		log.debug(strings.to_string(b))
	}
	l^ = {
		since = now,
	}
}

// loop_percentile returns, as text, the bucket bound that the given share
// of the turns took less time than.
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
