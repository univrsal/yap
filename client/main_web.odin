#+build wasi
package client

import "base:runtime"
import log "../common/wlog"
import "core:reflect"
import "core:strings"
import "core:time"

import glfw "wglfw"

import "../common"

/*
The web build's way in. A browser has no main loop to hand over: the
page's glue (web/shell.c) calls web_start once, then web_frame for every
frame the browser draws, which is what ui_startup and ui_frame are for.

Emscripten owns main, so Odin's own start-up never runs by itself:
web_start runs it (global initializers and @(init) procedures - the
crypto packages' tables among them), then builds the context - the
allocators and the logger - that is put back at the top of every call.
*/

@(private = "file")
g_context: runtime.Context
@(private = "file")
g_web_ui: ^UI
@(private = "file")
g_logs: Log_Lines
@(private = "file")
g_logger: log.Logger

@(default_calling_convention = "c")
foreign _ {
	// A parameter of the page's address, into buf; 0 if it isn't there.
	yap_query_param :: proc(name: cstring, buf: [^]u8, buf_size: i32) -> i32 ---
}

/*
query_param reads the page's address the way the desktop client reads
its command line:

	index.html?server=host:port   connect straight away
	index.html?log=debug          log level: debug, info, warn, error
*/
@(private = "file")
query_param :: proc(name: cstring) -> string {
	buf: [256]u8
	n := yap_query_param(name, raw_data(buf[:]), len(buf))
	return strings.clone(string(buf[:n]))
}

@(export)
web_start :: proc "c" () -> b32 {
	// Everything allocates through emscripten's malloc (web_alloc.odin),
	// including whatever the runtime's start-up sets up.
	g_context = web_context_init()
	context = g_context
	runtime._startup_runtime()

	level, known := reflect.enum_from_name(common.Log_Level, query_param("log"))
	if !known {
		level = .info
	}
	logger, ok := common.init_logging(level, "", {log_lines_sink, &g_logs})
	if !ok {
		return false
	}
	g_logger = logger
	g_context.logger = logger
	context.logger = logger
	web_context_set_logger(logger)

	server := query_param("server")

	g_web_ui = new(UI)
	if !ui_startup(
		g_web_ui,
		{
			key_path = default_config_path("client.key"),
			known_servers = default_config_path("known_servers"),
			server = server,
			logs = &g_logs,
			settings_path = default_config_path("settings.json"),
		},
	) {
		log.error("could not start the client")
		return false
	}
	return true
}

@(export)
web_frame :: proc "c" () {
	context = g_context
	if g_web_ui == nil {
		return
	}
	g_last_frame = time.tick_now()
	// A page doesn't end the way a program does: closing the tab is the
	// only way out, and the browser tears everything down itself.
	ui_frame(g_web_ui)
}

// When the last web_frame ran, for web_tick.
@(private = "file")
g_last_frame: time.Tick

// How long without a frame before web_tick takes over the connection:
// a few frames' worth even at 30 fps, so a slow frame isn't mistaken
// for a stopped one.
@(private = "file")
TICK_TAKEOVER :: 50 * time.Millisecond

/*
web_tick keeps the connection - and with it the voice, which is encoded,
decoded and mixed there (voice_step) - going when frames don't come. A
browser stops drawing a hidden tab, minimised or covered window, and
nothing else would give net_step its turn; the audio devices keep
running, but on rings nobody fills or drains. web/background.js calls
this every 10 ms from a worker's timer, which a hidden tab doesn't
throttle the way it does the page's own. While frames are coming it
does nothing.
*/
@(export)
web_tick :: proc "c" () {
	context = g_context
	if g_web_ui == nil || time.tick_since(g_last_frame) < TICK_TAKEOVER {
		return
	}
	net_step(g_web_ui)
}

// The page calls this whenever the tab changes size, and once at the
// start, so the canvas always fills it (web/index.html).
@(export)
web_resize :: proc "c" (width, height: i32) {
	context = g_context
	if g_web_ui != nil && g_web_ui.window != nil && width > 0 && height > 0 {
		glfw.SetWindowSize(g_web_ui.window, width, height)
	}
}
