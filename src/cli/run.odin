#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time/timezone"

import "client:conn"
import "client:platform"
import "tui"

// The terminal loop: draw, wait for a key, the mouse or the connection, handle
// it, draw again.

IDLE_MS :: 1000 // so that notices and typing indicators expire
ESCAPE_MS :: 40 // how long a lone Escape waits for the rest of a sequence

run_ui :: proc(opt: Options) -> bool {
	term: tui.Terminal
	if !tui.terminal_open(&term) {
		fmt.eprintln("yap-cli needs a terminal on its input and output. Use -print to only list the channels.")
		return false
	}
	// From here the screen is the terminal's alternate one, so whatever is written
	// to stderr (also by the C libraries, which don't go through the log) would
	// garble it: it goes to the log file instead.
	redirect_stderr(opt.log_file)
	defer tui.terminal_close(&term)
	interrupt_install()

	target := conn.Net_Target {
		key_path      = opt.key,
		server        = opt.server,
		password      = opt.password,
		known_servers = opt.known_servers,
		channel       = opt.channel,
	}
	s := start_session(target, opt)
	defer conn.session_free(s)

	app: App
	app_init(&app, &s.view, s.client)
	defer app_destroy(&app)
	app.known_servers = opt.known_servers
	app.device = opt.device
	app.tz, _ = timezone.region_load("local")
	defer timezone.region_destroy(app.tz)

	decoder: tui.Decoder
	defer tui.decoder_destroy(&decoder)
	events: [dynamic]tui.Event
	defer delete(events)
	prev, cur: tui.Buffer
	defer tui.buffer_destroy(&prev)
	defer tui.buffer_destroy(&cur)
	out: strings.Builder
	defer strings.builder_destroy(&out)
	have_prev := false
	style := notify_style()
	title_told: string
	defer delete(title_told)
	input: [4096]u8

	for !app.quit && !interrupted() {
		w, h := tui.terminal_size()
		if cur.w != w || cur.h != h {
			tui.buffer_resize(&cur, w, h)
			have_prev = false
		}
		app_frame(&app, &cur)
		tui.render_diff(&out, &prev if have_prev else nil, &cur)
		write_cursor(&out, &app)
		write_clipboard(&out, &app)
		write_notices(&out, &app, style, &title_told)
		tui.terminal_flush(&out)
		tui.buffer_copy(&prev, &cur)
		have_prev = true

		if app.reconnect {
			app.reconnect = false
			conn.session_free(s)
			s = start_session(target, opt)
			app.view, app.client = &s.view, s.client
			app.viewing, app.reading_told = 0, 0
		}

		pending := len(decoder.buf) > 0
		res := tui.terminal_wait(&term, ESCAPE_MS if pending else IDLE_MS)
		if tui.terminal_take_resized() {
			have_prev = false
		}
		clear(&events)
		if res.input {
			n := tui.terminal_read(input[:])
			if n == 0 {
				break // the terminal is gone
			}
			tui.decoder_feed(&decoder, input[:n], &events)
		} else if pending && !res.woken {
			tui.decoder_timeout(&decoder, &events)
		}
		for ev in events {
			app_event(&app, ev)
			if p, is := ev.(tui.Paste_Event); is {
				delete(p.text)
			}
		}
	}
	return true
}

// start_session opens a connection with the credentials from the command line,
// which stay for a later one.
@(private = "file")
start_session :: proc(target: conn.Net_Target, opt: Options) -> ^conn.Session {
	s := conn.session_new(target, tui.terminal_wake)
	dir := opt.download_dir
	if dir == "" {
		dir = platform.downloads_dir(context.temp_allocator)
	}
	s.client.files.download_dir = strings.clone(dir)
	conn.auth_credentials(s.client, opt.user, opt.user_password, opt.device)
	conn.session_start(s)
	return s
}

@(private = "file")
write_cursor :: proc(out: ^strings.Builder, a: ^App) {
	if a.cursor_shown {
		fmt.sbprintf(out, "\x1b[%d;%dH\x1b[?25h", a.cursor.y + 1, a.cursor.x + 1)
	} else {
		strings.write_string(out, "\x1b[?25l")
	}
}

// write_clipboard puts text a copy was asked for on the clipboard (OSC 52, which
// terminals pass on to the system's, also over ssh).
@(private = "file")
write_clipboard :: proc(out: ^strings.Builder, a: ^App) {
	if a.clipboard == "" {
		return
	}
	encoded, _ := base64.encode(transmute([]u8)a.clipboard, allocator = context.temp_allocator)
	fmt.sbprintf(out, "\x1b]52;c;%s\x07", encoded)
	delete(a.clipboard)
	a.clipboard = ""
}


// redirect_stderr sends what is written to stderr to the file (appending), or
// nowhere if there is none.
@(private = "file")
redirect_stderr :: proc(path: string) {
	target := strings.clone_to_cstring(path if path != "" else "/dev/null", context.temp_allocator)
	fd := posix.open(target, {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR})
	if fd >= 0 {
		posix.dup2(fd, posix.STDERR_FILENO)
		posix.close(fd)
	}
}

// How the terminal is told to announce something.
Notify_Style :: enum {
	Bell, // only the bell
	OSC_777, // VTE, foot, Konsole, ...
	OSC_9, // iTerm2, WezTerm, Windows Terminal, ...
}

// notify_style picks the desktop notification the terminal is likely to
// understand, from what it says it is.
notify_style :: proc() -> Notify_Style {
	program := os_getenv("TERM_PROGRAM")
	switch {
	case program == "iTerm.app", program == "WezTerm", program == "ghostty", os_getenv("WT_SESSION") != "":
		return .OSC_9
	case os_getenv("TERM") == "linux" || os_getenv("TERM") == "dumb":
		return .Bell
	}
	return .OSC_777
}

// write_notices announces what the app collected, and keeps the title current.
@(private = "file")
write_notices :: proc(out: ^strings.Builder, a: ^App, style: Notify_Style, told: ^string) {
	for n in take_notices(a) {
		strings.write_byte(out, 0x07)
		switch style {
		case .OSC_777:
			fmt.sbprintf(out, "\x1b]777;notify;%s;%s\x07", sanitize(n.title), sanitize(n.body))
		case .OSC_9:
			fmt.sbprintf(out, "\x1b]9;%s: %s\x07", sanitize(n.title), sanitize(n.body))
		case .Bell:
		}
		delete(n.title)
		delete(n.body)
	}
	if a.title != told^ {
		fmt.sbprintf(out, "\x1b]2;%s\x07", sanitize(a.title))
		delete(told^)
		told^ = strings.clone(a.title)
	}
}

// sanitize takes out what would end the sequence early or be taken for a part of it.
@(private = "file")
sanitize :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for r in s {
		if r >= 0x20 && r != 0x7f && r != ';' {
			strings.write_rune(&b, r)
		} else if r == ';' {
			strings.write_rune(&b, ',')
		} else {
			strings.write_byte(&b, ' ')
		}
	}
	return strings.to_string(b)
}

@(private = "file")
os_getenv :: proc(name: string) -> string {
	return os.get_env(name, context.temp_allocator)
}
