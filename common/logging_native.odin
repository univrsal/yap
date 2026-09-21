#+build !wasi
package common

import "core:terminal/ansi"
import "core:fmt"
import log "wlog"
import "core:os"
import "core:terminal"
import "core:time/datetime"
import "core:time/timezone"

// Where a desktop's log lines go: the terminal, in colour if it is one,
// and a file as well if one was asked for.
Log_Output :: struct {
	color: bool,
	file:  ^os.File,
	tz:    ^datetime.TZ_Region, // nil: timestamps in UTC
}

log_output_init :: proc(out: ^Log_Output, log_file: string) -> bool {
	out.color = terminal.is_terminal(os.stderr)
	// If the local zone can't be loaded, fall back to UTC.
	out.tz, _ = timezone.region_load("local")
	if log_file != "" {
		f, err := os.open(
			log_file,
			{.Write, .Create, .Append},
			os.Permissions{.Read_User, .Write_User, .Read_Group},
		)
		if err != nil {
			fmt.eprintfln("failed to open log file %s: %v", log_file, err)
			return false
		}
		out.file = f
	}
	return true
}

log_output_destroy :: proc(out: ^Log_Output) {
	if out.file != nil {
		os.close(out.file)
	}
	if out.tz != nil {
		timezone.region_destroy(out.tz)
	}
	out^ = {}
}

log_output_local_time :: proc(out: ^Log_Output, dt: datetime.DateTime) -> datetime.DateTime {
	if out.tz != nil {
		if local, ok := timezone.datetime_to_tz(dt, out.tz); ok {
			return local
		}
	}
	return dt
}

log_output_write :: proc(
	out: ^Log_Output,
	level: log.Level,
	timestamp, name, text: string,
) {
	RESET :: ansi.CSI + ansi.RESET + ansi.SGR
	RED :: ansi.CSI + ansi.FG_RED + ansi.SGR
	YELLOW :: ansi.CSI + ansi.FG_YELLOW + ansi.SGR
	DARK_GREY :: ansi.CSI + ansi.FG_BRIGHT_BLACK + ansi.SGR

	color: string
	switch {
	case level < .Info:
		color = DARK_GREY
	case level < .Warning:
		color = ""
	case level < .Error:
		color = YELLOW
	case:
		color = RED
	}

	if out.color && color != "" {
		fmt.eprintf("%s%s%s%s %s\n", timestamp, color, name, RESET, text)
	} else {
		fmt.eprintf("%s%s %s\n", timestamp, name, text)
	}
	if out.file != nil {
		fmt.fprintf(out.file, "%s%s %s\n", timestamp, name, text)
	}
}
