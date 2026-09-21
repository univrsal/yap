#+build !wasi
/*
Logging, as yap uses it: core:log, under another name.

A web build is compiled for WASI, which is where Odin has a clock and an
entropy source; but core:log doesn't build there, because its console
logger needs core:terminal, which has no WASI half. The logging calls
themselves are a few lines over context.logger, so the web build has
them written out (wlog_web.odin) and everything imports this package as
`log` instead - on a desktop it is core:log and nothing else.
*/
package wlog

import "core:log"

Level :: log.Level
Logger :: log.Logger
Options :: log.Options
Logger_Proc :: log.Logger_Proc

debug :: log.debug
info :: log.info
warn :: log.warn
error :: log.error
debugf :: log.debugf
infof :: log.infof
warnf :: log.warnf
errorf :: log.errorf
