#+build !wasi
// Logging as yap uses it: core:log under another name.
//
// The web build is compiled for WASI, where Odin has a clock and an entropy
// source. core:log doesn't build there because its console logger needs
// core:terminal, which has no WASI implementation. The logging calls
// themselves are only a few lines over context.logger, so the web build has
// them written out (see wlog_web.odin), and everything imports this package
// as `log` instead. On a desktop it is just core:log.
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
