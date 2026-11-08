#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:c"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

@(private = "file")
Winsize :: struct {
	rows, cols, xpixel, ypixel: c.ushort,
}

when ODIN_OS == .Linux {
	@(private = "file")
	TIOCGWINSZ :: 0x5413
} else {
	@(private = "file")
	TIOCGWINSZ :: 0x40087468
}

// The terminal while the program has it: raw, on its own screen, reporting the
// mouse and pastes. Restored by terminal_close.
Terminal :: struct {
	saved:   posix.termios,
	is_raw:  bool,
	wake_rd: posix.FD,
}

// The write end of the wake pipe, for terminal_wake and the resize signal, which
// can't be given a pointer to the Terminal.
@(private = "file")
wake_wr: posix.FD = -1
@(private = "file")
resized: bool

SEQ_ENTER :: "\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[2J"
SEQ_LEAVE :: "\x1b[?7h\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l\x1b[0m"

// terminal_open puts the terminal in raw mode and on its own screen. It fails if
// stdin is not a terminal.
terminal_open :: proc(t: ^Terminal) -> bool {
	if !bool(posix.isatty(posix.STDIN_FILENO)) || !bool(posix.isatty(posix.STDOUT_FILENO)) {
		return false
	}
	if posix.tcgetattr(posix.STDIN_FILENO, &t.saved) != .OK {
		return false
	}
	raw := t.saved
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_cflag += {.CS8}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) != .OK {
		return false
	}
	t.is_raw = true

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		terminal_close(t)
		return false
	}
	// A full pipe must not block the network thread or the signal handler.
	for fd in fds {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
	}
	t.wake_rd = fds[0]
	sync.atomic_store(&wake_wr, fds[1])
	posix.signal(posix.Signal(posix.SIGWINCH), on_winch)

	terminal_write(SEQ_ENTER)
	return true
}

// terminal_close gives the terminal back as it was. Safe to call twice.
terminal_close :: proc(t: ^Terminal) {
	if !t.is_raw {
		return
	}
	terminal_write(SEQ_LEAVE)
	posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &t.saved)
	t.is_raw = false
	if wr := sync.atomic_exchange(&wake_wr, -1); wr >= 0 {
		posix.close(wr)
		posix.close(t.wake_rd)
	}
}

@(private = "file")
on_winch :: proc "c" (_: posix.Signal) {
	sync.atomic_store(&resized, true)
	terminal_wake()
}

// terminal_wake makes terminal_wait return, from any thread (or a signal
// handler).
terminal_wake :: proc "c" () {
	wr := sync.atomic_load(&wake_wr)
	if wr >= 0 {
		b := [1]u8{1}
		posix.write(wr, raw_data(b[:]), 1)
	}
}

// terminal_size is the screen's width and height in cells.
terminal_size :: proc() -> (w, h: int) {
	ws: Winsize
	if ioctl(c.int(posix.STDOUT_FILENO), TIOCGWINSZ, &ws) != 0 || ws.cols == 0 || ws.rows == 0 {
		return 80, 24
	}
	return int(ws.cols), int(ws.rows)
}

// terminal_take_resized says whether the window changed size since the last call.
terminal_take_resized :: proc() -> bool {
	return sync.atomic_exchange(&resized, false)
}

Wait_Result :: struct {
	input: bool, // there are bytes to read from the terminal
	woken: bool, // terminal_wake was called
}

// terminal_wait waits up to `timeout_ms` (-1 for ever) for input or a wake-up.
terminal_wait :: proc(t: ^Terminal, timeout_ms: int) -> (res: Wait_Result) {
	fds := [2]posix.pollfd {
		{fd = posix.STDIN_FILENO, events = {.IN}},
		{fd = t.wake_rd, events = {.IN}},
	}
	if posix.poll(raw_data(fds[:]), 2, c.int(timeout_ms)) <= 0 {
		return
	}
	res.input = .IN in fds[0].revents
	if .IN in fds[1].revents {
		res.woken = true
		drain: [64]u8
		for posix.read(t.wake_rd, raw_data(drain[:]), len(drain)) > 0 {}
	}
	return
}

// terminal_read reads what the terminal has sent, up to len(buf) bytes. 0 means
// the terminal is gone.
terminal_read :: proc(buf: []u8) -> int {
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), len(buf))
	return int(max(n, 0))
}

// terminal_write writes everything, even when the terminal takes it in pieces.
terminal_write :: proc(s: string) {
	data := transmute([]u8)s
	for len(data) > 0 {
		n := posix.write(posix.STDOUT_FILENO, raw_data(data), len(data))
		if n < 0 {
			if posix.errno() == .EINTR || posix.errno() == .EAGAIN {
				continue
			}
			return
		}
		data = data[n:]
	}
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
