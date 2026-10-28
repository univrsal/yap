package server

import "core:fmt"
import "core:os"
import "core:terminal"
import "core:time"

// Progress is the status line of a command that takes a while (the importer),
// so that nobody takes it for hanging. On a terminal it is one line that is
// written over; otherwise (a file, a log) it is a new line every few seconds.
// It only prints when asked to, from the loop that does the work, and not
// more often than PROGRESS_EVERY.
Progress :: struct {
	label:   string, // what is going on: "reading import.jsonl"
	bytes:   bool, // `done` and `total` are bytes, not items
	start:   time.Tick,
	last:    time.Tick,
	tty:     bool,
	printed: bool, // something was written over on a terminal
	done:    i64, // as of the last update
}

PROGRESS_EVERY :: 2 * time.Second

// progress_start begins a phase. `total` is how much there will be, 0 if it
// isn't known.
progress_start :: proc(label: string, bytes := false) -> Progress {
	now := time.tick_now()
	return {
		label = label,
		bytes = bytes,
		start = now,
		last = now,
		tty = terminal.is_terminal(os.stderr),
	}
}

// progress_update says how far the phase is, and prints it if it is time.
progress_update :: proc(p: ^Progress, done, total: i64) {
	p.done = done
	now := time.tick_now()
	if time.tick_diff(p.last, now) < PROGRESS_EVERY {
		return
	}
	p.last = now
	progress_print(p, done, total)
}

// progress_finish ends the phase with one line that stays: how much was done
// as of the last update.
progress_finish :: proc(p: ^Progress) {
	if p.printed {
		fmt.eprint("\r\x1b[K")
	}
	took := time.duration_seconds(time.tick_diff(p.start, time.tick_now()))
	fmt.eprintfln("%s: %s, %.1f s", p.label, amount(p, p.done), took)
	p^ = {}
}

@(private = "file")
progress_print :: proc(p: ^Progress, done, total: i64) {
	took := time.duration_seconds(time.tick_diff(p.start, time.tick_now()))
	rate := f64(done) / took if took > 0 else 0
	text: string
	if total > 0 {
		left := (f64(total - done) / rate) if rate > 0 else 0
		text = fmt.tprintf(
			"%s: %d%%, %s of %s, %s/s, about %d s left",
			p.label,
			done * 100 / total,
			amount(p, done),
			amount(p, total),
			amount(p, i64(rate)),
			int(left) + 1,
		)
	} else {
		text = fmt.tprintf("%s: %s, %s/s", p.label, amount(p, done), amount(p, i64(rate)))
	}
	if p.tty {
		fmt.eprintf("\r\x1b[K%s", text)
		p.printed = true
	} else {
		fmt.eprintln(text)
	}
}

// amount writes a number of bytes as megabytes, or a number of items as it is.
@(private = "file")
amount :: proc(p: ^Progress, n: i64) -> string {
	if p.bytes {
		return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	}
	return fmt.tprintf("%d", n)
}
