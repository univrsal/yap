#+build darwin
package idle

import "core:time"

foreign import cg "system:CoreGraphics.framework"

@(private = "file")
COMBINED_SESSION_STATE :: 0
// kCGAnyInputEventType
@(private = "file")
ANY_INPUT_EVENT :: ~u32(0)

@(private = "file", default_calling_convention = "c")
foreign cg {
	CGEventSourceSecondsSinceLastEventType :: proc(state: i32, event_type: u32) -> f64 ---
}

@(private = "file")
threshold: f64

open :: proc(after: time.Duration, wayland_display, x11_display: rawptr) -> Source {
	threshold = time.duration_seconds(after)
	return .Mac
}

check :: proc() -> (idle: bool, known: bool) {
	since := CGEventSourceSecondsSinceLastEventType(COMBINED_SESSION_STATE, ANY_INPUT_EVENT)
	return since >= threshold, true
}

close :: proc() {}
