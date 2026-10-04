#+build wasi
package client

import "core:unicode/utf8"

import "client:platform"
import mu "vendor:microui"

/*
Touch and the phone keyboard, as the page hands them over (see
web/touch.js). GLFW's own touch support only makes a finger into a
mouse that presses wherever it lands, which microui can't use: it
decides what a press hits from what the pointer hovered in the frame
before, and a finger has no hover. And a drag through the channel list
would join every channel on the way.

So the page tells taps, vertical drags (scrolling) and sideways drags
(the sliders) apart, and they come here as a queue of plain pointer
and key events that is fed to microui one per frame: the pointer moves
to where the finger landed, two frames go by - one for microui to find
the panel under the pointer, one for the control in it - then it
presses, and lets go in the frame after. Typing from the phone's keyboard - which types into
a hidden field of the page's, the only thing that brings the keyboard
up - is queued the same way, since microui sees at most one backspace
per frame.
*/

@(private = "file")
Touch_Event_Kind :: enum {
	Move,
	Settle, // a frame with nothing new, for hover to catch up
	Press,
	Release,
	Key, // down and up again
	Text,
	Newline, // Enter, in a text area: a new line (Extra_Key.Newline)
}

@(private = "file")
Touch_Event :: struct {
	kind:   Touch_Event_Kind,
	x, y:   i32, // Move, in layout pixels
	key:    mu.Key,
	text:   [4]u8, // one character, UTF-8
	text_n: int,
}

@(private = "file")
g_touch: [dynamic]Touch_Event

// The focused text box is a text area, where the keyboard's Enter starts
// a new line rather than sending (touch_after_frame).
@(private = "file")
g_multiline: bool

@(default_calling_convention = "c")
foreign _ {
	// Takes the keyboard away: the page's hidden field loses the focus.
	yap_keyboard_hide :: proc() ---
	// Labels the keyboard's Enter key: a new line, or send.
	yap_keyboard_multiline :: proc(on: b32) ---
}

// touch_step feeds microui the next queued event. Called once per frame,
// before the layout.
touch_step :: proc(ui: ^UI) {
	if len(g_touch) == 0 {
		return
	}
	e := pop_front(&g_touch)
	ui_redraw(ui) // and with more queued, the frames to take them
	ctx := &ui.ctx
	switch e.kind {
	case .Move:
		mu.input_mouse_move(ctx, e.x, e.y)
	case .Settle:
	case .Press:
		mu.input_mouse_down(ctx, ctx.mouse_pos.x, ctx.mouse_pos.y, .LEFT)
	case .Release:
		mu.input_mouse_up(ctx, ctx.mouse_pos.x, ctx.mouse_pos.y, .LEFT)
	case .Key:
		mu.input_key_down(ctx, e.key)
		mu.input_key_up(ctx, e.key)
	case .Text:
		mu.input_text(ctx, string(e.text[:e.text_n]))
	case .Newline:
		ui.keys += {.Newline}
	}
}

// touch_after_frame puts the keyboard away once no text box has the
// focus any more (a message sent and the page changed, say), and labels
// its Enter key for the one that has.
touch_after_frame :: proc(ui: ^UI) {
	focused, multiline := false, false
	for b in ui.text_boxes {
		if b.id == ui.ctx.focus_id {
			focused, multiline = true, b.multiline
		}
	}
	if ui.text_focused && !focused {
		yap_keyboard_hide()
	}
	ui.text_focused = focused
	if focused && multiline != g_multiline {
		g_multiline = multiline
		yap_keyboard_multiline(b32(multiline))
	}
}

@(private = "file")
queue :: proc(e: Touch_Event) {
	append(&g_touch, e)
	ui_wake()
}

// Page coordinates (CSS pixels, from the canvas' corner) to layout pixels.
@(private = "file")
to_layout :: proc(x, y: f64) -> (i32, i32) {
	return i32(x * f64(g_ui.input_scale)), i32(y * f64(g_ui.input_scale))
}

@(private = "file")
queue_move :: proc(x, y: f64) {
	lx, ly := to_layout(x, y)
	// Moves in a row only need the last one.
	if n := len(g_touch); n > 0 && g_touch[n - 1].kind == .Move {
		g_touch[n - 1].x, g_touch[n - 1].y = lx, ly
		return
	}
	queue({kind = .Move, x = lx, y = ly})
}

// The finger has gone: the pointer goes somewhere nothing is, so no
// hover - a button's hint, say - stays behind where it was.
@(private = "file")
queue_lift :: proc() {
	queue({kind = .Move, x = -1000, y = -1000})
}

@(private = "file")
text_box_at :: proc(x, y: f64) -> bool {
	lx, ly := to_layout(x, y)
	for b in g_ui.text_boxes {
		if mu.rect_overlaps_vec2(b.rect, {lx, ly}) {
			return true
		}
	}
	return false
}

// A tap: a click where the finger was. On a text box, the caret goes to
// the end (in a text area, of the line tapped), where the keyboard's
// typing arrives.
@(export)
web_touch_tap :: proc "c" (x, y: f64) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	on_text := text_box_at(x, y)
	queue_move(x, y)
	queue({kind = .Settle})
	queue({kind = .Press})
	queue({kind = .Release})
	if on_text {
		queue({kind = .Key, key = .END})
	}
	queue_lift()
}

// Whether a tap here lands on a text box, so the page brings up the
// keyboard while it's still handling the tap.
@(export)
web_text_box_at :: proc "c" (x, y: f64) -> b32 {
	context = platform.callback_context()
	return g_ui != nil && b32(text_box_at(x, y))
}

// A sideways drag: pressed where it started, then following the finger.
@(export)
web_touch_drag_begin :: proc "c" (x, y: f64) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	queue_move(x, y)
	queue({kind = .Settle})
	queue({kind = .Press})
}

@(export)
web_touch_drag_move :: proc "c" (x, y: f64) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	queue_move(x, y)
}

@(export)
web_touch_drag_end :: proc "c" () {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	queue({kind = .Release})
	queue_lift()
}

// A vertical drag scrolls what's under the finger, by `dy` page pixels
// (positive: the finger went up, towards what's further down).
@(export)
web_touch_scroll :: proc "c" (x, y, dy: f64) {
	context = platform.callback_context()
	if g_ui == nil {
		return
	}
	// Scrolling goes to the container under the pointer, which is
	// worked out in the layout this frame, so it can move right away -
	// nothing is pressed.
	if len(g_touch) == 0 {
		lx, ly := to_layout(x, y)
		mu.input_mouse_move(&g_ui.ctx, lx, ly)
	}
	mu.input_scroll(&g_ui.ctx, 0, i32(dy * f64(g_ui.input_scale)))
	ui_wake()
}

// Typing from the phone's keyboard: one character, a backspace, Enter
// (in a text area, a new line: there's no Shift for it, and the send
// button sends).
@(export)
web_text_rune :: proc "c" (r: rune) {
	context = platform.callback_context()
	e := Touch_Event {
		kind = .Text,
	}
	buf, n := utf8.encode_rune(r)
	e.text, e.text_n = buf, n
	queue(e)
}

@(export)
web_text_backspace :: proc "c" () {
	context = platform.callback_context()
	queue({kind = .Key, key = .BACKSPACE})
}

@(export)
web_text_enter :: proc "c" () {
	context = platform.callback_context()
	queue({kind = .Newline} if g_multiline else {kind = .Key, key = .RETURN})
}
