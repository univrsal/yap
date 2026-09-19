package common

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

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

@(private = "file")
Logger_Data :: struct {
	mutex: sync.Mutex,
	tz:    ^datetime.TZ_Region, // nil: timestamps in UTC
	color: bool,
	file:  ^os.File,
	sink:  Log_Sink,
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
	data.color = terminal.is_terminal(os.stderr)
	// If the local zone can't be loaded, fall back to UTC.
	data.tz, _ = timezone.region_load("local")

	if log_file != "" {
		f, err := os.open(
			log_file,
			{.Write, .Create, .Append},
			os.Permissions{.Read_User, .Write_User, .Read_Group},
		)
		if err != nil {
			fmt.eprintfln("failed to open log file %s: %v", log_file, err)
			destroy_logger_data(data)
			return
		}
		data.file = f
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
	if data.file != nil {
		os.close(data.file)
	}
	if data.tz != nil {
		timezone.region_destroy(data.tz)
	}
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

	RESET :: ansi.CSI + ansi.RESET + ansi.SGR
	RED :: ansi.CSI + ansi.FG_RED + ansi.SGR
	YELLOW :: ansi.CSI + ansi.FG_YELLOW + ansi.SGR
	DARK_GREY :: ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR

	name, color: string
	switch {
	case level < .Info:
		name, color = "DEBUG", DARK_GREY
	case level < .Warning:
		name, color = "INFO ", ""
	case level < .Error:
		name, color = "WARN ", YELLOW
	case level < .Fatal:
		name, color = "ERROR", RED
	case:
		name, color = "FATAL", RED
	}

	dt, _ := time.time_to_datetime(time.now())
	if data.tz != nil {
		if local, ok := timezone.datetime_to_tz(dt, data.tz); ok {
			dt = local
		}
	}

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
	if data.color && color != "" {
		fmt.eprintf("%s%s%s%s %s\n", timestamp, color, name, RESET, text)
	} else {
		fmt.eprintf("%s%s %s\n", timestamp, name, text)
	}
	if data.file != nil {
		fmt.fprintf(data.file, "%s%s %s\n", timestamp, name, text)
	}
	if data.sink.procedure != nil {
		data.sink.procedure(data.sink.data, level, fmt.tprintf("%s%s %s", timestamp, name, text))
	}
}
