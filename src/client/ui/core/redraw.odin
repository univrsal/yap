package core

import redraw_pkg "client:ui/redraw"
import "core:time"

// redraw_now asks for frames right now, from the UI's own thread.
redraw_now :: proc "contextless" (env: ^Env) {
	redraw_pkg.now(&env.redraw)
}

// redraw_at asks for a frame by `at`, for things that change with the clock
// alone. The layout asks again in every frame that still needs it.
redraw_at :: proc(env: ^Env, at: time.Tick) {
	redraw_pkg.at(&env.redraw, at)
}

redraw_in :: proc(env: ^Env, after: time.Duration) {
	redraw_pkg.after(&env.redraw, after)
}

// How often things that move smoothly (a fade, the level meter) are redrawn.
ANIMATION_FRAME :: redraw_pkg.ANIMATION_FRAME

// wake asks the UI's loop for a frame from any thread (ui_wake). Set when the
// UI starts, for the callbacks of the web build that are not given the UI.
wake: proc "c" ()
