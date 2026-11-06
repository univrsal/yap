#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:sys/posix"
import "core:time/timezone"

import "client:conn"
import "client:platform"
import "client:script"
import "client:settings"
import "tui"

// The terminal loop: draw, wait for a key, the mouse or the connection, handle
// it, draw again.

IDLE_MS :: 1000 // so that notices and typing indicators expire
SCRIPT_TICK_MS :: 100 // the longest wait while scripts run
SCRIPT_BUDGET :: 2 * time.Millisecond
ESCAPE_MS :: 40 // how long a lone Escape waits for the rest of a sequence

run_ui :: proc(opt: Options) -> bool {
	targets := initial_targets(opt)
	defer {
		for &t in targets {
			target_destroy(&t)
		}
		delete(targets)
	}
	if len(targets) == 0 {
		fmt.eprintln("yap-cli needs a server: yap-cli host[:port], or join servers in the window client first.")
		return false
	}
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

	app: App
	defer app_destroy(&app)
	// The scripts first, so that each connection is attached to them as it is made.
	app.scripts = start_scripts()
	defer stop_scripts(&app)
	for t, i in targets {
		// The credentials on the command line are for the server given there.
		connect_server(&app, t, opt, with_credentials = i == 0 && opt.server != "")
	}
	defer {
		for s in app.servers {
			if s.session != nil {
				close_session(&app, s.session)
			}
		}
	}
	app.channel_w = CHANNEL_W_DEFAULT

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

		handle_requests(&app, opt)
		if app.scripts != nil {
			script.runtime_step(app.scripts, SCRIPT_BUDGET)
			script_notices(&app)
		}

		pending := len(decoder.buf) > 0
		wait_ms := IDLE_MS
		if app.scripts != nil && script.runtime_scripts(app.scripts) > 0 {
			wait_ms = SCRIPT_TICK_MS // their timers are on time
		}
		res := tui.terminal_wait(&term, ESCAPE_MS if pending else wait_ms)
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

// initial_targets are the servers to connect to: the one on the command line,
// or else those joined in the window client (read from its settings, which this
// client never writes).
@(private = "file")
initial_targets :: proc(opt: Options) -> (targets: [dynamic]conn.Net_Target) {
	if opt.server != "" {
		append(
			&targets,
			conn.Net_Target {
				key_path = opt.key,
				known_servers = opt.known_servers,
				server = strings.clone(opt.server),
				password = strings.clone(opt.password),
				channel = strings.clone(opt.channel),
			},
		)
		return
	}
	path := platform.default_config_path("settings.json")
	defer delete(path)
	if path == "" {
		return
	}
	st := settings.settings_load(path)
	defer settings.settings_destroy(&st)
	for j in st.joined_servers {
		append(
			&targets,
			conn.Net_Target {
				key_path = opt.key,
				known_servers = opt.known_servers,
				server = strings.clone(j.address),
				password = strings.clone(j.password),
				look_at = strings.clone(j.channel),
			},
		)
	}
	return
}

// connect_server opens a connection and adds the server to the app.
@(private = "file")
connect_server :: proc(a: ^App, t: conn.Net_Target, opt: Options, with_credentials: bool) -> int {
	s := open_session(a, t, opt, with_credentials)
	index := app_add_server(a, &s.view, s.client, s)
	app_set_target(a, index, t)
	return index
}

@(private = "file")
open_session :: proc(a: ^App, t: conn.Net_Target, opt: Options, with_credentials: bool) -> ^conn.Session {
	s := conn.session_new(t, tui.terminal_wake)
	dir := opt.download_dir
	if dir == "" {
		dir = platform.downloads_dir(context.temp_allocator)
	}
	s.client.files.download_dir = strings.clone(dir)
	if with_credentials {
		conn.auth_credentials(s.client, opt.user, opt.user_password, opt.device)
	}
	if a.scripts != nil {
		script.runtime_attach(a.scripts, s.client)
	}
	conn.session_start(s)
	return s
}

// close_session ends a connection, after the scripts let go of it.
@(private = "file")
close_session :: proc(a: ^App, s: ^conn.Session) {
	if a.scripts != nil {
		script.runtime_detach(a.scripts, s.client)
	}
	conn.session_free(s)
}

// start_scripts starts the scripts in the config folder (the window client's
// too), if there are any. They are given a little time every turn of the loop.
@(private = "file")
start_scripts :: proc() -> ^script.Runtime {
	dir := platform.default_config_path("scripts")
	defer delete(dir)
	if dir == "" {
		return nil
	}
	rt := script.runtime_create(dir)
	script.runtime_load(rt)
	script.runtime_notifications_to_ui(rt)
	return rt
}

@(private = "file")
stop_scripts :: proc(a: ^App) {
	if a.scripts != nil {
		script.runtime_destroy(a.scripts)
		a.scripts = nil
	}
}

// handle_requests does what the app asked for the connections: connect to
// another server, leave one, or connect again.
@(private = "file")
handle_requests :: proc(a: ^App, opt: Options) {
	requests := a.requests
	a.requests = nil
	defer delete(requests)
	for req in requests {
		switch req.kind {
		case .Connect:
			target := conn.Net_Target {
				key_path      = opt.key,
				known_servers = opt.known_servers,
				server        = req.address,
				password      = req.password,
			}
			app_switch(a, connect_server(a, target, opt, false))
		case .Disconnect:
			if req.index >= 0 && req.index < len(a.servers) {
				session := a.servers[req.index].session
				if len(a.servers) == 1 {
					a.quit = true
				} else {
					app_remove_server(a, req.index)
				}
				if session != nil {
					close_session(a, session)
				}
			}
		case .Reconnect:
			if req.index >= 0 && req.index < len(a.servers) {
				t := a.servers[req.index].target
				s := open_session(a, t, opt, req.index == 0 && opt.server != "")
				old := app_replace_connection(a, req.index, &s.view, s.client, s)
				if old != nil {
					close_session(a, old)
				}
			}
		}
		delete(req.address)
		delete(req.password)
	}
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
