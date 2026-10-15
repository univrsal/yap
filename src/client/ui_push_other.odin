#+build !wasi
package client

import "client:conn"

// Web Push only exists in the web client (ui_push_web.odin). Desktop clients use the
// system's own notifications instead, and their page is never considered hidden.

page_hidden :: proc() -> bool {return false}
push_covers :: proc(ns: ^Net_Session) -> bool {return false}
push_frame :: proc(ui: ^UI) {}
push_settings :: proc(ui: ^UI, v: ^conn.View) {}
