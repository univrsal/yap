package memtrack

import "core:fmt"
import "core:strings"

/*
A report is text, so that the server's can be sent to a client as it
is: a line starting with "# " is a heading, any other is three columns
split by tabs - an amount, a detail, and what it's about. The client
shows it in columns (ui_memory.odin), and log_text lines it up for a
log.
*/

// Something counted elsewhere, for a report's "Elsewhere": SQLite's
// own memory, the GPU's textures.
Extra :: struct {
	name:   string,
	bytes:  int,
	detail: string,
}

/*
report is what the process has and where it's gone, in `allocator`:
the process's numbers, then `extras`, then what's counted, by file
(the `files` with the most) and by line of code (the `lines` with the
most).
*/
report :: proc(
	extras: []Extra = nil,
	files := 25,
	lines := 40,
	allocator := context.allocator,
) -> string {
	context.allocator = context.temp_allocator
	b := strings.builder_make(allocator)
	p := process()
	t := totals()

	heading(&b, "This process")
	if p.wasm_memory != 0 {
		row(&b, p.wasm_memory, "", "the page's memory (it never shrinks)")
	} else if p.resident != 0 {
		row(&b, p.resident, peak_string(p.resident_peak), "resident (in RAM)")
	} else if p.resident_peak != 0 {
		row(&b, p.resident_peak, "", "resident, at most")
	}
	if p.private != 0 {
		row(&b, p.private, "", "private (the process's own)")
	}
	if p.heap_known {
		row(&b, p.heap_in_use, "", "heap in use")
		if ENABLED {
			row(
				&b,
				t.live,
				fmt.tprintf("%d allocations", t.count),
				"    counted (by file and line below)",
			)
			row(
				&b,
				max(p.heap_in_use - t.live, 0),
				"",
				"    not counted: C libraries, core:os's scratch",
			)
		}
		row(&b, p.heap_free, "", "heap free: freed, kept by malloc for reuse")
		if p.wasm_memory == 0 && p.resident != 0 {
			if rest := p.resident - p.heap_in_use - p.heap_free; rest > 0 {
				row(&b, rest, "roughly", "not heap: code, stacks, GPU driver, mapped files")
			}
		}
	} else if ENABLED {
		row(&b, t.live, fmt.tprintf("%d allocations", t.count), "counted (by file and line below)")
	}

	if len(extras) > 0 {
		heading(&b, "Elsewhere")
		for e in extras {
			row(&b, e.bytes, e.detail, e.name)
		}
	}

	when !ENABLED {
		heading(&b, "Allocations aren't counted in this build (YAP_MEMTRACK=false)")
	} else {
		heading(&b, "Counted")
		row(&b, t.live, fmt.tprintf("%d allocations", t.count), "live")
		row(&b, t.peak, "", "live, at most")
		row(&b, int(t.alloc_bytes), fmt.tprintf("%d allocations", t.allocs), "allocated, ever")
		row(&b, t.overhead, fmt.tprintf("%d lines of code", t.sites), "the counting itself")

		all := sites()
		by := by_file(all)
		heading(&b, "Live, by file")
		for f, i in by {
			if i == files || (f.live == 0 && i > 0) {
				break
			}
			row(&b, f.live, fmt.tprintf("%d, %s at most", f.count, bytes_string(f.peak)), f.file)
		}
		heading(&b, "Live, by line")
		for s, i in all {
			if i == lines || (s.live == 0 && i > 0) {
				break
			}
			row(
				&b,
				s.live,
				fmt.tprintf("%d, %s at most", s.count, bytes_string(s.peak)),
				site_string(s),
			)
		}
	}
	return strings.to_string(b)
}

/*
summary is a report in a line, for logging every so often: enough to
see a trend in a long log, and the files that hold the most.
*/
summary :: proc(extras: []Extra = nil, allocator := context.allocator) -> string {
	context.allocator = context.temp_allocator
	b := strings.builder_make(allocator)
	p := process()
	t := totals()
	strings.write_string(&b, "memory:")
	if p.wasm_memory != 0 {
		fmt.sbprintf(&b, " page %s", bytes_string(p.wasm_memory))
	} else if p.resident != 0 {
		fmt.sbprintf(
			&b,
			" resident %s (peak %s)",
			bytes_string(p.resident),
			bytes_string(p.resident_peak),
		)
	}
	if p.private != 0 {
		fmt.sbprintf(&b, ", private %s", bytes_string(p.private))
	}
	if p.heap_known {
		fmt.sbprintf(
			&b,
			", heap %s in use + %s free",
			bytes_string(p.heap_in_use),
			bytes_string(p.heap_free),
		)
	}
	when ENABLED {
		fmt.sbprintf(
			&b,
			", counted %s in %d (peak %s)",
			bytes_string(t.live),
			t.count,
			bytes_string(t.peak),
		)
	}
	for e in extras {
		fmt.sbprintf(&b, ", %s %s", e.name, bytes_string(e.bytes))
	}
	when ENABLED {
		strings.write_string(&b, "; most:")
		for f, i in by_file(sites()) {
			if i == 5 || f.live == 0 {
				break
			}
			fmt.sbprintf(&b, "%s %s %s", "" if i == 0 else ",", f.file, bytes_string(f.live))
		}
	}
	return strings.to_string(b)
}

// log_text is a report with its columns lined up, for a log.
log_text :: proc(report: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rest := report
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "# ") {
			fmt.sbprintf(&b, "\n%s\n", line[2:])
			continue
		}
		amount, _, after := strings.partition(line, "\t")
		detail, _, about := strings.partition(after, "\t")
		fmt.sbprintf(&b, "%10s  %-34s  %s\n", amount, detail, about)
	}
	return strings.to_string(b)
}

// site_string is where a line of code is: conn/messages.odin:120 (decode_message).
site_string :: proc(s: Site, allocator := context.temp_allocator) -> string {
	if s.loc.line == 0 {
		return fmt.aprintf("%s (%s)", s.loc.file_path, s.loc.procedure, allocator = allocator)
	}
	return fmt.aprintf(
		"%s:%d (%s)",
		short_path(s.loc.file_path),
		s.loc.line,
		s.loc.procedure,
		allocator = allocator,
	)
}

@(private = "file")
heading :: proc(b: ^strings.Builder, text: string) {
	fmt.sbprintf(b, "# %s\n", text)
}

// The detail and what it's about mustn't break the columns.
@(private = "file")
row :: proc(b: ^strings.Builder, bytes: int, detail, about: string) {
	clean :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "\t", " ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
		return out
	}
	fmt.sbprintf(b, "%s\t%s\t%s\n", bytes_string(bytes), clean(detail), clean(about))
}

@(private = "file")
peak_string :: proc(peak: int) -> string {
	return fmt.tprintf("peak %s", bytes_string(peak)) if peak != 0 else ""
}
