// Profiling of scripts: how long each handler takes, so that a script that
// slows the client down can be found in the log.
//
// Every run of a handler, command or filter is timed (its running time, not
// the time it waited between slices, see Task.spent), and added to the
// script's Profile under the handler's name. Two things are logged:
//
//   - a call that took at least SLOW_CALL (SLOW_FILTER for a filter, which
//     runs on the network thread and is allowed only FILTER_LIMIT) is
//     logged as a warning right away, but for one handler at most every
//     SLOW_LOG_EVERY, with how many more there were in between;
//   - every PROFILE_EVERY, one line per script that did anything: how many
//     calls, how much time they took in all and of the time that went by,
//     and the PROFILE_SHOWN handlers that took the most. It is logged as
//     info if it matters (some calls were slow, or they added up to
//     PROFILE_NOTABLE), and as debug otherwise.
//
// It all happens in the thread that runs the script. A call costs one clock
// reading more than it did.
package script

import "core:fmt"
import log "common:wlog"
import "core:slice"
import "core:strings"
import "core:time"

SLOW_CALL :: 10 * time.Millisecond
SLOW_FILTER :: 1 * time.Millisecond
SLOW_LOG_EVERY :: 10 * time.Second
PROFILE_EVERY :: 60 * time.Second
PROFILE_SHOWN :: 4
PROFILE_NOTABLE :: 5 * time.Millisecond
// How many handlers a script is told apart by (it can register commands under
// any name); the rest are counted together.
PROFILE_NAMES :: 64
PROFILE_OTHER :: "(other)"

Profile_Stat :: struct {
	name:   string, // owned
	calls:  int,
	failed: int, // ended in an error, or were killed
	total:  time.Duration,
	max:    time.Duration,
	// Slow calls since the last one that was logged, and when that was.
	slow:   int,
	logged: time.Tick,
}

Profile :: struct {
	stats: [dynamic]Profile_Stat,
	since: time.Tick, // the start of what stats covers
	// What was slow in it, for the line that sums it up.
	slow:  int,
}

// profile_record adds a finished run of `name` that took `spent`. A `sync` run
// is a filter.
@(private)
profile_record :: proc(s: ^Script, name: string, spent: time.Duration, failed, sync: bool) {
	if s.meta {
		return
	}
	p := &s.profile
	now := time.tick_now()
	if p.since == {} {
		p.since = now
	}
	st := profile_stat(s, name)
	st.calls += 1
	st.total += spent
	st.max = max(st.max, spent)
	if failed {
		st.failed += 1
	}
	if spent < (SLOW_FILTER if sync else SLOW_CALL) {
		return
	}
	p.slow += 1
	st.slow += 1
	if st.logged == {} || time.tick_diff(st.logged, now) >= SLOW_LOG_EVERY {
		more := ""
		if st.slow > 1 {
			more = fmt.tprintf(" (and %d more slow ones since the last note)", st.slow - 1)
		}
		log.warnf(
			"script %s: %s%s took %v%s",
			s.name,
			"the filter " if sync else "",
			name,
			spent,
			more,
		)
		st.logged, st.slow = now, 0
	}
}

@(private = "file")
profile_stat :: proc(s: ^Script, name: string) -> ^Profile_Stat {
	p := &s.profile
	for &st in p.stats {
		if st.name == name {
			return &st
		}
	}
	if len(p.stats) < PROFILE_NAMES {
		return profile_add(s, name)
	}
	// Too many names: the rest is counted together.
	for &st in p.stats {
		if st.name == PROFILE_OTHER {
			return &st
		}
	}
	return profile_add(s, PROFILE_OTHER)
}

@(private = "file")
profile_add :: proc(s: ^Script, name: string) -> ^Profile_Stat {
	p := &s.profile
	if p.stats.allocator.procedure == nil {
		p.stats.allocator = s.allocator
	}
	append(&p.stats, Profile_Stat{name = strings.clone(name, s.allocator)})
	return &p.stats[len(p.stats) - 1]
}

// profile_text sums up what was recorded over `window`, or "" if nothing was.
// `total` is the time all the calls took.
profile_text :: proc(
	name: string,
	p: ^Profile,
	window: time.Duration,
) -> (
	text: string,
	total: time.Duration,
) {
	if len(p.stats) == 0 {
		return
	}
	calls, failed := 0, 0
	for st in p.stats {
		calls += st.calls
		failed += st.failed
		total += st.total
	}
	busiest := slice.clone(p.stats[:], context.temp_allocator)
	slice.sort_by(busiest, proc(a, b: Profile_Stat) -> bool {
		return a.total > b.total
	})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "script %s: in the last %v, %d calls took %v", name, window, calls, total)
	if window > 0 {
		fmt.sbprintf(&b, " (%.2f%% of the time)", 100 * f64(total) / f64(window))
	}
	if failed > 0 {
		fmt.sbprintf(&b, ", %d failed", failed)
	}
	strings.write_string(&b, "; most: ")
	for st, i in busiest {
		if i >= PROFILE_SHOWN {
			break
		}
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%s %d x %v (slowest %v)", st.name, st.calls, st.total, st.max)
	}
	return strings.to_string(b), total
}

// profile_flush logs the script's totals and starts counting again.
@(private)
profile_flush :: proc(s: ^Script, now: time.Tick) {
	p := &s.profile
	defer profile_reset(s, now)
	text, total := profile_text(s.name, p, time.tick_diff(p.since, now))
	if text == "" {
		return
	}
	if p.slow > 0 || total >= PROFILE_NOTABLE {
		log.info(text)
	} else {
		log.debug(text)
	}
}

@(private = "file")
profile_reset :: proc(s: ^Script, now: time.Tick) {
	p := &s.profile
	for &st in p.stats {
		delete(st.name, s.allocator)
	}
	clear(&p.stats)
	p.since, p.slow = now, 0
}

@(private)
profile_destroy :: proc(s: ^Script) {
	for &st in s.profile.stats {
		delete(st.name, s.allocator)
	}
	delete(s.profile.stats)
	s.profile = {}
}
