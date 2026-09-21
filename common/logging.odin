package common

import "core:fmt"
import log "wlog"
import "core:strings"
import "core:sync"
import "core:time"

/*
A core:log logger, so code just uses log.info, log.warnf, etc.

Differences from core:log's console logger:
- local time with milliseconds rather than UTC to the second
- everything goes to stderr, so lines can't reorder between streams
- a mutex around each line, so it's safe to log from several threads
- optionally also appends to a file (without colors)
- optionally hands each line to a sink, e.g. a UI log panel

	2026-09-19 12:34:56.789 INFO  listening on udp :7777
*/

// Level names as typed on the command line (core:flags matches enum
// names exactly, hence lowercase).
Log_Level :: enum {
	debug,
	info,
	warn,
	error,
}

// Log_Sink receives every logged line (timestamp, level and text, no
// colors or newline). It's called with the logger's lock held, from
// whichever thread logged.
Log_Sink :: struct {
	procedure: proc(data: rawptr, level: log.Level, line: string),
	data:      rawptr,
}

@(private)
Logger_Data :: struct {
	mutex:  sync.Mutex,
	// Where the lines go: a terminal and maybe a file on a desktop, the
	// browser's console in a web build (logging_native/logging_web).
	output: Log_Output,
	sink:   Log_Sink,
}

// init_logging creates the logger. Install it with `context.logger = logger`
// and release it with destroy_logging.
init_logging :: proc(
	level: Log_Level,
	log_file := "",
	sink := Log_Sink{},
) -> (
	logger: log.Logger,
	ok: bool,
) {
	data := new(Logger_Data)
	data.sink = sink
	if !log_output_init(&data.output, log_file) {
		destroy_logger_data(data)
		return
	}

	lowest: log.Level
	switch level {
	case .debug:
		lowest = .Debug
	case .info:
		lowest = .Info
	case .warn:
		lowest = .Warning
	case .error:
		lowest = .Error
	}
	return log.Logger{logger_proc, data, lowest, nil}, true
}

destroy_logging :: proc(logger: log.Logger) {
	destroy_logger_data((^Logger_Data)(logger.data))
}

@(private = "file")
destroy_logger_data :: proc(data: ^Logger_Data) {
	log_output_destroy(&data.output)
	free(data)
}

@(private = "file")
logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	data := (^Logger_Data)(logger_data)

	name: string
	switch {
	case level < .Info:
		name = "DEBUG"
	case level < .Warning:
		name = "INFO "
	case level < .Error:
		name = "WARN "
	case level < .Fatal:
		name = "ERROR"
	case:
		name = "FATAL"
	}

	dt, _ := time.time_to_datetime(time.now())
	dt = log_output_local_time(&data.output, dt)

	backing: [64]byte
	b := strings.builder_from_bytes(backing[:])
	fmt.sbprintf(
		&b,
		"%d-%02d-%02d %02d:%02d:%02d.%03d ",
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		dt.nano / 1_000_000,
	)
	timestamp := strings.to_string(b)

	sync.guard(&data.mutex)
	log_output_write(&data.output, level, timestamp, name, text)
	if data.sink.procedure != nil {
		data.sink.procedure(data.sink.data, level, fmt.tprintf("%s%s %s", timestamp, name, text))
	}
}
