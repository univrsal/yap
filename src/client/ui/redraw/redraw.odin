// Asking the UI's loop for another frame. A frame costs the same whether
// anything changed or not, so the loop sleeps until something asks for one
// (see frame_due in ui/frame.odin). Anything that fades, counts or otherwise
// changes with the clock asks again in every frame that still needs it.
//
// This is a package of its own so that the pieces of the UI that live in
// sub-packages can ask for frames without importing the UI.
package redraw

import "core:time"

// How many frames are drawn after input, so that a click is seen by the frame
// after the one that handled it (widgets react to the previous frame's layout).
SETTLE_FRAMES :: 2

// How often things that move smoothly (a fade, the level meter) are redrawn.
ANIMATION_FRAME :: time.Second / 30

Request :: struct {
	frames: int, // how many more frames to draw regardless
	at:     time.Tick, // when the clock will next change something on screen (zero: nothing will)
}

// now asks for frames right now, from the UI's own thread.
now :: proc "contextless" (r: ^Request) {
	r.frames = max(r.frames, SETTLE_FRAMES)
}

// at asks for a frame by `tick`, for things that change with the clock alone.
at :: proc(r: ^Request, tick: time.Tick) {
	if r.at == {} || time.tick_diff(tick, r.at) > 0 {
		r.at = tick
	}
}

after :: proc(r: ^Request, d: time.Duration) {
	at(r, time.tick_add(time.tick_now(), max(d, 0)))
}
