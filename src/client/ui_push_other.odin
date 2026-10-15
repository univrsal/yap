#+build !wasi
package client

import "client:conn"

// Web Push is the web client's (ui_push_web.odin): a desktop client
// has the desktop's own notices, and isn't out of sight but hidden.

page_hidden :: proc() -> bool {return false}
push_covers :: proc(ns: ^Net_Session) -> bool {return false}
push_frame :: proc(ui: ^UI) {}
push_settings :: proc(ui: ^UI, v: ^conn.View) {}
