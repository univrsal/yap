#+build !wasi
package client

import "core:testing"
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
