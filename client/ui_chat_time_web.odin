#+build wasi
package client

import "core:time/datetime"

/*
A browser has no timezone database to read, and core:time/timezone
reaches for files a page hasn't got. The page does know its own offset
from UTC, though, which is all a chat timestamp needs.
*/

@(default_calling_convention = "c")
foreign _ {
	// Minutes to add to UTC to get local time, from the page's clock.
	yap_utc_offset_minutes :: proc() -> i32 ---
}

chat_load_timezone :: proc(ui: ^UI) {}
chat_unload_timezone :: proc(ui: ^UI) {}

chat_local_time :: proc(ui: ^UI, dt: datetime.DateTime) -> datetime.DateTime {
	offset := datetime.Delta{seconds = i64(yap_utc_offset_minutes()) * 60}
	local, err := datetime.add_delta_to_datetime(dt, offset)
	return local if err == .None else dt
}
