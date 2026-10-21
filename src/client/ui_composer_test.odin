#+build !wasi
package client

import "core:math"
import "core:testing"
import "core:time"
import mu "vendor:microui"

import "common:proto"

@(private = "file")
Composer_Test :: struct {
	ui:      ^UI,
	buf:     [256]u8,
	n:       int,
	editing: proto.Msg_Id,
	conv:    proto.Conv_Id,
	area:    Text_Area,
	box:     mu.Id,
	rect:    mu.Rect,
}

@(private = "file")
composer_test_start :: proc(text: string) -> ^Composer_Test {
	ct := new(Composer_Test)
	ct.ui = new(UI)
	ct.ui.view = &ct.ui.no_view
	mu.init(&ct.ui.ctx)
	ct.ui.ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * 8}
	ct.ui.ctx.text_height = proc(font: mu.Font) -> i32 {return 16}
	ct.n = copy(ct.buf[:], text)
	return ct
}

@(private = "file")
composer_test_end :: proc(ct: ^Composer_Test) {
	ui_select_destroy(ct.ui)
	free(ct.ui)
	free(ct)
}

@(private = "file")
composer_test_of :: proc(ct: ^Composer_Test) -> Composer {
	return {buf = ct.buf[:], len = &ct.n, editing = &ct.editing, conv = &ct.conv, area = &ct.area}
}

// composer_test_frame lays out a composer with only its send button.
@(private = "file")
composer_test_frame :: proc(ct: ^Composer_Test) {
	ui := ct.ui
	ctx := &ui.ctx
	c := composer_test_of(ct)
	mu.begin(ctx)
	if mu.begin_window(ctx, "w", {0, 0, 400, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		composer_row(ui, composer_height(ui, c))
		_, ct.box, ct.rect = composer_box(ui, c)
		composer_buttons(ui, ct.rect, 1)
		composer_send_button(ui, c, "send", "Send")
		composer_buttons_end(ui)
		mu.end_window(ctx)
	}
	mu.end(ctx)
}

// draws_color says whether the last frame drew anything in `color`.
@(private = "file")
draws_color :: proc(ctx: ^mu.Context, color: mu.Color) -> bool {
	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		#partial switch c in variant {
		case ^mu.Command_Icon:
			if c.color == color {
				return true
			}
		case ^mu.Command_Rect:
			if c.color == color {
				return true
			}
		}
	}
	return false
}

// The box is two lines tall with nothing in it, and keeps the strip for its
// buttons below the text.
@(test)
test_composer_two_lines :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	for _ in 0 ..< 2 {
		composer_test_frame(ct)
	}
	single := text_area_single(&ct.ui.ctx, ct.ui.ctx.style.font)
	testing.expect_value(t, ct.rect.h, single + 16 + COMPOSER_BUTTON + COMPOSER_INSET)
}

// The send button is in the accent color only once there is something to send.
@(test)
test_composer_send_accent :: proc(t: ^testing.T) {
	ct := composer_test_start("   ")
	defer composer_test_end(ct)
	composer_test_frame(ct)
	testing.expect(t, !draws_color(&ct.ui.ctx, theme.accent))
	ct.n = copy(ct.buf[:], "hello")
	composer_test_frame(ct)
	testing.expect(t, draws_color(&ct.ui.ctx, theme.accent))
}

// Pressing in the strip along the box's bottom, beside the buttons, leaves the
// caret where it was.
@(test)
test_composer_footer_keeps_caret :: proc(t: ^testing.T) {
	ct := composer_test_start("hello")
	defer composer_test_end(ct)
	ctx := &ct.ui.ctx
	composer_test_frame(ct)
	mu.set_focus(ctx, ct.box)
	composer_test_frame(ct)
	ctx.textbox_state.selection = {4, 4}
	at := mu.Vec2{ct.rect.x + 20, ct.rect.y + ct.rect.h - COMPOSER_INSET - 2}
	mu.input_mouse_move(ctx, at.x, at.y)
	composer_test_frame(ct)
	mu.input_mouse_down(ctx, at.x, at.y, .LEFT)
	composer_test_frame(ct)
	testing.expect_value(t, ctx.textbox_state.selection, [2]int{4, 4})
	mu.input_mouse_up(ctx, at.x, at.y, .LEFT)
	composer_test_frame(ct)

	// Pressing on the text does move it.
	mu.input_mouse_move(ctx, ct.rect.x + 6, ct.rect.y + 6)
	composer_test_frame(ct)
	mu.input_mouse_down(ctx, ct.rect.x + 6, ct.rect.y + 6, .LEFT)
	composer_test_frame(ct)
	testing.expect_value(t, ctx.textbox_state.selection, [2]int{0, 0})
}

// While Shift+Enter makes the box grow, the frame each new line is typed in
// neither scrolls nor shows a scrollbar, though the box only grows in the next
// one. Past the most lines it grows to, the scrollbar shows.
@(test)
test_composer_grows_without_scrollbar :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ctx := &ct.ui.ctx
	composer_test_frame(ct)
	mu.set_focus(ctx, ct.box)
	composer_test_frame(ct)
	newline :: proc(ct: ^Composer_Test) {
		ctx := &ct.ui.ctx
		mu.input_key_down(ctx, .SHIFT)
		mu.input_key_down(ctx, .RETURN)
		composer_test_frame(ct)
		mu.input_key_up(ctx, .RETURN)
		mu.input_key_up(ctx, .SHIFT)
	}
	for _ in 1 ..< TEXT_AREA_MAX_LINES {
		newline(ct)
		testing.expect_value(t, ct.area.bar.w, 0)
		testing.expect_value(t, ct.area.scroll, 0)
		composer_test_frame(ct)
	}
	newline(ct)
	composer_test_frame(ct)
	testing.expect(t, ct.area.bar.w > 0)
	testing.expect(t, ct.area.scroll > 0)
}

// A window as narrow as a phone's, or a touch screen, gets controls a
// fingertip tall, and icon and composer buttons as wide; otherwise they are
// roomier than microui's own.
@(test)
test_style_for_phones :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	ctx := &ui.ctx
	row :: proc(ctx: ^mu.Context) -> i32 {return ctx.style.size.y + 2 * ctx.style.padding}

	style_apply(ui, 1000)
	testing.expect(t, !ui.compact)
	testing.expect_value(t, row(ctx), 26)
	testing.expect_value(t, icon_button_w(ctx), ICON_BUTTON)
	testing.expect_value(t, composer_button_size(ctx), COMPOSER_BUTTON)

	style_apply(ui, 420)
	testing.expect(t, ui.compact)
	testing.expect_value(t, row(ctx), 40)
	testing.expect_value(t, icon_button_w(ctx), 40)
	testing.expect_value(t, composer_button_size(ctx), 40)

	ui.touched = true
	style_apply(ui, 1000)
	testing.expect(t, ui.compact)
}

// A spinner asks for a frame by its next step while it is on screen, and none
// when it is clipped away.
@(test)
test_spinner_redraws_while_shown :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	ctx := &ui.ctx
	mu.begin(ctx)
	if mu.begin_window(ctx, "w", {0, 0, 400, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		spinner(ui, {1000, 1000, 20, 20}) // outside the window
		testing.expect_value(t, ui.redraw_at, time.Tick{})
		spinner(ui, {10, 10, 20, 20})
		testing.expect(t, ui.redraw_at != {})
		left := time.tick_diff(time.tick_now(), ui.redraw_at)
		testing.expect(t, left > 0 && left <= SPINNER_STEP)
		mu.end_window(ctx)
	}
	mu.end(ctx)
}

// A notch of the mouse wheel reaches microui over a few frames, less in each
// than the one before, and all of it in the end.
@(test)
test_wheel_scrolls_smoothly :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	ui.scroll_left = {0, 2 * WHEEL_NOTCH}
	total, last: i32 = 0, max(i32)
	frames := 0
	for ui.scroll_left != {} && frames < 100 {
		// A frame later than the last.
		if ui.scroll_at != {} {
			ui.scroll_at = time.tick_add(time.tick_now(), -SCROLL_FRAME)
		}
		ui.ctx.scroll_delta = {}
		scroll_step(ui)
		got := ui.ctx.scroll_delta.y
		testing.expectf(
			t,
			got > 0 && got <= last,
			"frame %d scrolled %d after %d",
			frames,
			got,
			last,
		)
		total, last = total + got, got
		frames += 1
	}
	testing.expect_value(t, total, 2 * WHEEL_NOTCH)
	// What is left shrinks by e every SCROLL_EASE, down to the last pixel,
	// and then by a pixel a frame (a few at most).
	most := int(math.ceil(SCROLL_EASE * 60 * math.ln(f64(2 * WHEEL_NOTCH)))) + 5
	testing.expectf(t, frames >= 4 && frames <= most, "took %d frames (at most %d)", frames, most)
	testing.expect_value(t, ui.scroll_at, time.Tick{})
}

// While a message's picture is decoded again, its place is the shape it will
// have; one never decoded takes the whole area.
@(test)
test_picture_placeholder_shape :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	defer delete(ui.images.sizes)
	area := mu.Rect{10, 10, 480, 160}
	placeholder :: proc(ui: ^UI, id: u64, area: mu.Rect) -> (got: mu.Rect) {
		ctx := &ui.ctx
		mu.begin(ctx)
		if mu.begin_window(ctx, "w", {0, 0, 600, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
			image_fitted(ui, {kind = .Picture, id = id}, .Wanted, nil, area)
			mu.end_window(ctx)
		}
		mu.end(ctx)
		cmd: ^mu.Command
		for variant in mu.next_command_iterator(ctx, &cmd) {
			if r, ok := variant.(^mu.Command_Rect); ok && r.color == theme.image_bg {
				got = r.rect
			}
		}
		return
	}
	ui.images.sizes[{kind = .Picture, id = 7}] = {800, 600}
	testing.expect_value(t, placeholder(ui, 7, area), mu.Rect{10, 10, 213, 160})
	testing.expect_value(t, placeholder(ui, 8, area), area)
}

// A container's scrollbar shows once it scrolls, and fades out after a while,
// asking for frames only until it is gone. With the pointer on it, it shows.
@(test)
test_scrollbar_fades :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	ctx := &ui.ctx
	defer delete(ui.scrollbar_fades)
	strip := mu.Rect{388, 0, 12, 300}
	step :: proc(ui: ^UI, strip: mu.Rect, scroll: i32, ago: time.Duration) -> (f: Scrollbar_Fade) {
		ctx := &ui.ctx
		ui.redraw_at = {}
		mu.begin(ctx)
		if mu.begin_window(
			ctx,
			"w",
			{0, 0, 400, 300},
			{.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL},
		) {
			cnt := mu.get_current_container(ctx)
			cnt.scroll.y = scroll
			if fade, ok := &ui.scrollbar_fades[cnt]; ok && ago > 0 {
				fade.moved = time.tick_add(time.tick_now(), -ago)
			}
			scrollbar_frame(ui, strip, .SCROLL_BASE)
			f = ui.scrollbar_fades[cnt]
			mu.end_window(ctx)
		}
		mu.end(ctx)
		return
	}
	f := step(ui, strip, 0, 0)
	testing.expect_value(t, f.alpha, 0) // not scrolled yet
	f = step(ui, strip, 40, 0)
	testing.expect_value(t, f.alpha, 1)
	testing.expect(t, ui.redraw_at != {}) // for when it starts to fade
	f = step(ui, strip, 40, SCROLLBAR_SHOWN + SCROLLBAR_FADE / 2)
	testing.expect(t, f.alpha > 0.3 && f.alpha < 0.7)
	testing.expect(t, ui.redraw_at != {})
	f = step(ui, strip, 40, SCROLLBAR_SHOWN + SCROLLBAR_FADE + time.Millisecond)
	testing.expect_value(t, f.alpha, 0)
	f = step(ui, strip, 40, 0)
	testing.expect_value(t, f.alpha, 0) // and stays gone
	testing.expect_value(t, ui.redraw_at, time.Tick{})
	mu.input_mouse_move(ctx, 394, 100)
	step(ui, strip, 40, 0) // the pointer reaches the window
	f = step(ui, strip, 40, 0)
	testing.expect(t, f.hovered)
	testing.expect_value(t, f.alpha, 1)
}

// A setting's dropdown reports a pick other than the current choice, as the
// value of its enum.
@(test)
test_choice_dropdowns :: proc(t: ^testing.T) {
	ct := composer_test_start("")
	defer composer_test_end(ct)
	ui := ct.ui
	pick :: proc(ui: ^UI, row: int, current: Theme_Choice) -> (got: Theme_Choice, ok: bool) {
		ctx := &ui.ctx
		mu.begin(ctx)
		if mu.begin_window(ctx, "w", {0, 0, 400, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
			mu.layout_row(ctx, {CHOICE_WIDTH})
			// As if `row` was picked from the open list in the last frame.
			ui.dropdown.picked, ui.dropdown.picked_id = row, mu.get_id(ctx, "theme")
			got, ok = enum_dropdown(ui, "theme", THEME_CHOICE_LABELS, current)
			mu.end_window(ctx)
		}
		mu.end(ctx)
		return
	}
	_, ok := pick(ui, int(Theme_Choice.Dark), .Dark)
	testing.expect(t, !ok)
	got: Theme_Choice
	got, ok = pick(ui, int(Theme_Choice.Light), .Dark)
	testing.expect(t, ok)
	testing.expect_value(t, got, Theme_Choice.Light)
}
