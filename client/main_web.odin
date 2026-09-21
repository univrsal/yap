#+build wasi
package client

import "base:runtime"
import log "../common/wlog"
import "core:strings"

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
	// The `server` parameter of the page's address, so a link can say
	// which server to connect to: index.html?server=host:port.
	yap_query_server :: proc(buf: [^]u8, buf_size: i32) -> i32 ---
}

@(export)
web_start :: proc "c" () -> b32 {
	// Everything allocates through emscripten's malloc (web_alloc.odin),
	// including whatever the runtime's start-up sets up.
	g_context = web_context_init()
	context = g_context
	runtime._startup_runtime()

	logger, ok := common.init_logging(.info, "", {log_lines_sink, &g_logs})
	if !ok {
		return false
	}
	g_logger = logger
	g_context.logger = logger
	context.logger = logger
	web_context_set_logger(logger)

	server_buf: [256]u8
	server: string
	if n := yap_query_server(raw_data(server_buf[:]), len(server_buf)); n > 0 {
		server = strings.clone(string(server_buf[:n]))
	}

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
	// A page doesn't end the way a program does: closing the tab is the
	// only way out, and the browser tears everything down itself.
	ui_frame(g_web_ui)
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
