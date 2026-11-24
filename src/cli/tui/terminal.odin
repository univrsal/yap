package tui

import "core:strconv"
import "core:strings"
import "core:time"

// What the terminal layer does the same everywhere. The system's part, raw mode,
// the size, waiting and reading, is in terminal_posix.odin and terminal_windows.odin.

SEQ_ENTER :: "\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[2J"
SEQ_LEAVE :: "\x1b[?7h\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l\x1b[0m"

Wait_Result :: struct {
	input: bool, // there are bytes to read from the terminal
	woken: bool, // terminal_wake was called
}

// terminal_flush writes a built frame.
terminal_flush :: proc(b: ^strings.Builder) {
	terminal_write(strings.to_string(b^))
	strings.builder_reset(b)
}

// terminal_probe_widths asks the terminal how many cells it moves the cursor for
// each rune: it prints the rune in the first column and asks where the cursor is.
// Under tmux the answers are tmux's own idea, not that of the terminal behind it.
// Gives nothing if the terminal does not answer in time.
terminal_probe_widths :: proc(
	t: ^Terminal,
	runes: []rune,
	allocator := context.allocator,
) -> (
	widths: []int,
	ok: bool,
) {
	BATCH :: 64
	widths = make([]int, len(runes), allocator)
	pending := make([dynamic]u8, context.temp_allocator)
	for start := 0; start < len(runes); start += BATCH {
		batch := runes[start:min(start + BATCH, len(runes))]
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		for r in batch {
			strings.write_string(&b, "\x1b[1;1H\x1b[K")
			strings.write_rune(&b, r)
			strings.write_string(&b, "\x1b[6n")
		}
		terminal_write(strings.to_string(b))
		got := 0
		deadline := time.tick_now()
		for got < len(batch) {
			if time.tick_diff(deadline, time.tick_now()) > 1500 * time.Millisecond {
				delete(widths, allocator)
				return nil, false
			}
			res := terminal_wait(t, 100)
			if !res.input {
				continue
			}
			buf: [256]u8
			n := terminal_read(buf[:])
			if n == 0 {
				delete(widths, allocator)
				return nil, false
			}
			append(&pending, ..buf[:n])
			// ESC [ row ; col R
			for {
				end := -1
				for c, i in pending {
					if c == 'R' {
						end = i
						break
					}
				}
				if end < 0 {
					break
				}
				reply := string(pending[:end])
				if semi := strings.index_byte(reply, ';'); semi >= 0 && got < len(batch) {
					col, _ := strconv.parse_int(reply[semi + 1:])
					widths[start + got] = col - 1
					got += 1
				}
				remove_range(&pending, 0, end + 1)
			}
		}
	}
	return widths, true
}
