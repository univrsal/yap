package client

import "core:time"
import mu "vendor:microui"

import "client:render"

// Scrollbars are thin, and fade out when nothing scrolls. microui draws a
// panel's or a window's scrollbar with draw_frame, its track (SCROLL_BASE) and
// then its thumb (SCROLL_THUMB), while that container is the current one, so
// draw_frame_themed hands them to scrollbar_frame, which keeps track of when
// each container last scrolled.
//
// The thumb is a pill SCROLLBAR_THIN wide at the outer edge of the strip that
// microui keeps for it (style.scrollbar_size, which is still what it takes and
// where it can be grabbed). With the pointer on the strip it is
// SCROLLBAR_WIDE, over a faint track. It shows for SCROLLBAR_SHOWN after the
// container scrolled (by the wheel, by dragging it, or by its content moving
// it, as the timeline does for new messages) or while the pointer is on it,
// and then fades out over SCROLLBAR_FADE. A container that hasn't scrolled
// since it was first drawn shows none until the pointer is on it.
//
// A text area's scrollbar (ui_text_area.odin) is drawn the same way, without
// fading: it only has one while its text doesn't fit.

SCROLLBAR_THIN :: 4
SCROLLBAR_WIDE :: 8
SCROLLBAR_SHOWN :: 800 * time.Millisecond
SCROLLBAR_FADE :: 300 * time.Millisecond

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

// scrollbar_frame draws a container's scrollbar track or thumb for microui
// (draw_frame_themed).
scrollbar_frame :: proc(ui: ^UI, rect: mu.Rect, colorid: mu.Color_Type) {
	ctx := &ui.ctx
	if ctx.container_stack.idx == 0 {
		return
	}
	cnt := mu.get_current_container(ctx)
	if cnt not_in ui.scrollbar_fades {
		ui.scrollbar_fades[cnt] = {}
	}
	f := &ui.scrollbar_fades[cnt]
	if colorid == .SCROLL_BASE {
		now := time.tick_now()
		if f.seen && f.scroll != cnt.scroll {
			f.moved = now
		}
		f.seen, f.scroll = true, cnt.scroll
		f.hovered = mu.mouse_over(ctx, rect)
		f.alpha = 0
		if f.hovered {
			f.alpha = 1
		} else if f.moved != {} {
			since := time.tick_diff(f.moved, now)
			switch {
			case since < SCROLLBAR_SHOWN:
				f.alpha = 1
				ui_redraw_at(ui, time.tick_add(f.moved, SCROLLBAR_SHOWN))
			case since < SCROLLBAR_SHOWN + SCROLLBAR_FADE:
				f.alpha = 1 - f32(since - SCROLLBAR_SHOWN) / f32(SCROLLBAR_FADE)
				ui_redraw_in(ui, ANIMATION_FRAME)
			case:
				f.moved = {} // faded out
			}
		}
	}
	scrollbar_draw(ctx, rect, colorid, f.alpha, f.hovered)
}

// scrollbar_draw draws a scrollbar's track (`colorid` SCROLL_BASE, only
// while the pointer is on it) or thumb in the strip or thumb rect that
// microui gives it, `alpha` visible.
scrollbar_draw :: proc(
	ctx: ^mu.Context,
	rect: mu.Rect,
	colorid: mu.Color_Type,
	alpha: f32,
	hovered: bool,
) {
	if alpha <= 0 || (colorid == .SCROLL_BASE && !hovered) {
		return
	}
	color := ctx.style.colors[colorid]
	color.a = u8(f32(color.a) * alpha)
	thick := i32(SCROLLBAR_WIDE if hovered else SCROLLBAR_THIN)
	// Along the strip's outer edge (right, or bottom for a horizontal one),
	// a pixel in from it.
	r := rect
	if r.h >= r.w {
		thick = min(thick, r.w)
		r.x, r.w = r.x + r.w - thick - 1, thick
	} else {
		thick = min(thick, r.h)
		r.y, r.h = r.y + r.h - thick - 1, thick
	}
	render.draw_rounded(ctx, r, color, min(r.w, r.h) / 2)
}
