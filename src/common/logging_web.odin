#+build wasi
package common

import log "wlog"
import "core:strings"
import "core:time/datetime"

/*
In a browser the log goes to the page's console, which is where anyone
debugging a web build will be looking anyway. Warnings and errors go
through the console's own levels so they stand out and keep their stack
traces; everything else is a plain line.

There are no log files, and timestamps stay in UTC: working out the
page's timezone would mean carrying the browser's offset in here for
the sake of a prefix the console already stamps itself.
*/

Log_Output :: struct {}

@(default_calling_convention = "c")
foreign _ {
	emscripten_console_log :: proc(text: cstring) ---
	emscripten_console_warn :: proc(text: cstring) ---
	emscripten_console_error :: proc(text: cstring) ---
}

log_output_init :: proc(out: ^Log_Output, log_file: string) -> bool {
	return true
}

log_output_destroy :: proc(out: ^Log_Output) {}

log_output_local_time :: proc(out: ^Log_Output, dt: datetime.DateTime) -> datetime.DateTime {
	return dt
}

log_output_write :: proc(out: ^Log_Output, level: log.Level, timestamp, name, text: string) {
	line := strings.concatenate({timestamp, name, " ", text}, context.temp_allocator)
	c := strings.clone_to_cstring(line, context.temp_allocator)
	switch {
	case level < .Warning:
		emscripten_console_log(c)
	case level < .Error:
		emscripten_console_warn(c)
	case:
		emscripten_console_error(c)
	}
}
