#+build windows
package idle

import "core:time"

foreign import user32 "system:user32.lib"
foreign import kernel32 "system:kernel32.lib"

@(private = "file")
LASTINPUTINFO :: struct {
	cbSize: u32,
	dwTime: u32, // GetTickCount when the last input came
}

@(private = "file", default_calling_convention = "system")
foreign user32 {
	GetLastInputInfo :: proc(plii: ^LASTINPUTINFO) -> b32 ---
}

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetTickCount :: proc() -> u32 ---
}

@(private = "file")
threshold_ms: u32

open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	threshold_ms = u32(clamp(time.duration_milliseconds(after), 0, f64(max(u32))))
	return .Windows
}

check :: proc() -> (idle: bool, known: bool) {
	info := LASTINPUTINFO {
		cbSize = size_of(LASTINPUTINFO),
	}
	if !GetLastInputInfo(&info) {
		return false, false
	}
	// Both wrap after 49.7 days, together.
	return GetTickCount() - info.dwTime >= threshold_ms, true
}

close :: proc() {}
