#+build wasi
/*
The web half of the logging calls: what core:log does, written out, since
core:log itself doesn't build for WASI (see wlog_native.odin). Each call
formats its text and hands it to context.logger, exactly as core:log's do.
*/
package wlog

import "base:runtime"
import "core:fmt"

Level :: runtime.Logger_Level
Logger :: runtime.Logger
Options :: runtime.Logger_Options
Logger_Proc :: runtime.Logger_Proc

debug :: proc(args: ..any, sep := " ", location := #caller_location) {
	log(.Debug, ..args, sep = sep, location = location)
}
info :: proc(args: ..any, sep := " ", location := #caller_location) {
	log(.Info, ..args, sep = sep, location = location)
}
warn :: proc(args: ..any, sep := " ", location := #caller_location) {
	log(.Warning, ..args, sep = sep, location = location)
}
error :: proc(args: ..any, sep := " ", location := #caller_location) {
	log(.Error, ..args, sep = sep, location = location)
}

debugf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	logf(.Debug, fmt_str, ..args, location = location)
}
infof :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	logf(.Info, fmt_str, ..args, location = location)
}
warnf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	logf(.Warning, fmt_str, ..args, location = location)
}
errorf :: proc(fmt_str: string, args: ..any, location := #caller_location) {
	logf(.Error, fmt_str, ..args, location = location)
}

@(private)
log :: proc(level: Level, args: ..any, sep := " ", location := #caller_location) {
	logger := context.logger
	if logger.procedure == nil || level < logger.lowest_level {
		return
	}
	logger.procedure(logger.data, level, fmt.tprint(..args, sep = sep), logger.options, location)
}

@(private)
logf :: proc(level: Level, fmt_str: string, args: ..any, location := #caller_location) {
	logger := context.logger
	if logger.procedure == nil || level < logger.lowest_level {
		return
	}
	logger.procedure(logger.data, level, fmt.tprintf(fmt_str, ..args), logger.options, location)
}
