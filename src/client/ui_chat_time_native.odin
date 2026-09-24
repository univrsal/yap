#+build !wasi
package client

import "core:time/datetime"
import "core:time/timezone"

// Chat timestamps are shown in the local zone, which a desktop reads
// from the system's timezone database.
chat_load_timezone :: proc(ui: ^UI) {
	ui.chat.tz, _ = timezone.region_load("local")
}

chat_unload_timezone :: proc(ui: ^UI) {
	timezone.region_destroy(ui.chat.tz)
}

chat_local_time :: proc(ui: ^UI, dt: datetime.DateTime) -> datetime.DateTime {
	if ui.chat.tz != nil {
		if local, ok := timezone.datetime_to_tz(dt, ui.chat.tz); ok {
			return local
		}
	}
	return dt
}
