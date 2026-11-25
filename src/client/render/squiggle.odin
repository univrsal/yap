package render

import "core:math"
import mu "vendor:microui"

// A squiggle is the wavy line under a misspelled word. microui only has rects,
// which are snapped to physical pixels each on their own, so a wave built from
// them turns into steps of uneven size at a fractional scale and into blocks at
// a high one. So the renderer draws it itself, in physical pixels: a sine wave
// a line thick (line_thickness), one column of pixels at a time, with the
// pixels it only partly covers drawn partly transparent.

// An icon command with this id draws a squiggle across its rect (draw_squiggle).
SQUIGGLE_ICON :: mu.Icon(UI_ICON_BASE - 4)

// How tall the band a squiggle waves in is, and how long one wave is, in
// logical pixels.
SQUIGGLE_HEIGHT :: 3
@(private = "file")
SQUIGGLE_PERIOD :: 4

// draw_squiggle draws a wavy line along the band `rect`, which is
// SQUIGGLE_HEIGHT tall: under a word, its bottom at the bottom of the line.
draw_squiggle :: proc(ctx: ^mu.Context, rect: mu.Rect, color: mu.Color) {
	if rect.w > 0 {
		mu.draw_icon(ctx, SQUIGGLE_ICON, rect, color)
	}
}

// One column of a squiggle, in physical pixels: the line covers it from `top`
// to `bottom`.
@(private)
Squiggle_Column :: struct {
	x:           f32,
	top, bottom: f32,
}

// squiggle_column is where the line crosses column `i` (counted from the
// squiggle's start) of a squiggle at scale `s` in a band from `y0` to `y1`.
// The line is thicker up and down where the wave is steep, so that it looks
// as thick everywhere.
@(private)
squiggle_column :: proc(i: int, y0, y1, s: f32) -> (top, bottom: f32) {
	t := line_thickness(s)
	amp := max((y1 - y0 - t) / 2, 0)
	period := SQUIGGLE_PERIOD * s
	k := 2 * math.PI / period
	x := f32(i) + 0.5
	mid := (y0 + y1) / 2 + amp * math.sin(k * x)
	slope := amp * k * math.cos(k * x)
	half := t / 2 * math.sqrt(1 + slope * slope)
	return max(mid - half, y0), min(mid + half, y1)
}
