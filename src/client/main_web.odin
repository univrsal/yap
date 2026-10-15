#+build wasi
package client

import "base:runtime"
import log "common:wlog"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"

import glfw "client:wglfw"

import "client:audio"
import "client:conn"
import "client:platform"
import "common:."

// The web build's entry point. A browser has no main loop to hand over, so
// the page's glue code (web/shell.c) calls web_start once and then web_frame
// for every frame the browser draws, which is what ui_startup and ui_frame
// are for.
//
// Emscripten owns main, so Odin's own start-up never runs by itself.
// web_start runs it (global initializers and @(init) procedures, including
// the crypto packages' tables) and then builds the context (the allocators
// and the logger) that is restored at the top of every exported call.

@(private = "file")
g_context: runtime.Context
@(private = "file")
g_web_ui: ^UI
@(private = "file")
g_logs: conn.Log_Lines
@(private = "file")
g_logger: log.Logger

@(default_calling_convention = "c")
foreign _ {
	// Reads a parameter of the page's address into buf. Returns 0 if it is missing.
	yap_query_param :: proc(name: cstring, buf: [^]u8, buf_size: i32) -> i32 ---
}

// query_param reads a parameter of the page's address, the same way the
// desktop client reads its command line:
//
//     index.html?server=host:port   connect straight away
//     index.html?log=debug          log level: debug, info, warn, error
//     index.html?audio_period=20    audio device period in ms (audio/voice_io.odin)
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
	g_context = platform.web_context_init()
	context = g_context
	runtime._startup_runtime()

	level, known := reflect.enum_from_name(common.Log_Level, query_param("log"))
	if !known {
		level = .info
	}
	logger, ok := common.init_logging(level, "", {conn.log_lines_sink, &g_logs})
	if !ok {
		return false
	}
	g_logger = logger
	g_context.logger = logger
	context.logger = logger
	platform.web_context_set_logger(logger)
	log.infof("yap %s", common.version_string())

	server := query_param("server")

	// 10 to 100 ms. At the top end, two periods and a frame still fit in the
	// 0.5 s capture ring (see capture_backlog).
	if ms, parsed := strconv.parse_uint(query_param("audio_period")); parsed {
		audio.web_device_period_ms = u32(clamp(ms, 10, 100))
	}
	log.debugf(
		"audio: %d ms device period (%d frames)",
		audio.device_period_ms(),
		audio.device_period_samples() / audio.CHANNELS,
	)

	g_web_ui = new(UI)
	if !ui_startup(
		g_web_ui,
		{
			key_path = platform.default_config_path("client.key"),
			known_servers = platform.default_config_path("known_servers"),
			server = server,
			logs = &g_logs,
			settings_path = platform.default_config_path("settings.json"),
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
	// A page doesn't end the way a program does. Closing the tab is the
	// only way out, and the browser tears everything down itself.
	ui_frame(g_web_ui)
}

// When the last web_frame ran, used by web_tick.
@(private = "file")
g_last_frame: time.Tick

// How long without a frame before web_tick takes over the connection. This is
// a few frames' worth even at 30 fps, so a slow frame isn't mistaken for a
// stopped one.
@(private = "file")
TICK_TAKEOVER :: 50 * time.Millisecond

// web_tick keeps the connection going when no frames come, and with it the
// voice, which is encoded, decoded and mixed there (see voice_step). A browser
// stops drawing a hidden tab or a minimized or covered window, and nothing
// else would give net_step its turn. The audio devices keep running, but on
// rings that nobody fills or drains. web/background.js calls this every 10 ms
// from a worker's timer, which a hidden tab doesn't throttle the way it
// throttles the page's own timers. While frames are coming it does nothing.
// It also keeps track of whether we are idle or out of sight (activity_step),
// which the frames would otherwise do. A hidden page is exactly when the
// server needs to know this, so that it can send us push notifications.
@(export)
web_tick :: proc "c" () {
	context = g_context
	if g_web_ui == nil || time.tick_since(g_last_frame) < TICK_TAKEOVER {
		return
	}
	activity_step(g_web_ui)
	net_step(g_web_ui)
}

// web_visibility is called when the page has just been hidden or become visible
// again (web/background.js). The servers are informed immediately, before anything
// else runs: a phone suspends a page in the background within moments, so neither a
// frame nor web_tick may run first. Until a server is told, it assumes we're looking
// at the page and doesn't send push notifications.
@(export)
web_visibility :: proc "c" () {
	context = g_context
	if g_web_ui == nil {
		return
	}
	activity_step(g_web_ui)
	net_step(g_web_ui)
}

// The page calls this whenever the tab changes size, and once at the start,
// so the canvas always fills it (see web/index.html).
@(export)
web_resize :: proc "c" (width, height: i32) {
	context = g_context
	if g_web_ui != nil && g_web_ui.window != nil && width > 0 && height > 0 {
		glfw.SetWindowSize(g_web_ui.window, width, height)
	}
}
