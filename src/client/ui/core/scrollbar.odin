package core

import "core:time"
import mu "vendor:microui"

// What is known of a container's scrollbar between frames.
Scrollbar_Fade :: struct {
	seen:    bool,
	scroll:  mu.Vec2, // where it was scrolled to when last drawn
	moved:   time.Tick, // when that last changed, or zero
	// For its thumb, drawn right after its track: how visible, and whether
	// the pointer is on the strip.
	alpha:   f32,
	hovered: bool,
}
