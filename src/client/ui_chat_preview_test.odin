#+build !wasi
package client

import "core:fmt"
import "core:testing"
import mu "vendor:microui"

import "common:proto"

// The preview fits the box the text area was sized to: it never needs a
// scrollbar the text area didn't (it used to have one for a single line).
@(test)
test_composer_preview_fits :: proc(t: ^testing.T) {
	for text in ([]string{"one line", "one\ntwo", "one\ntwo\nthree", "a longer line that wraps round"}) {
		ui := new(UI)
		defer free(ui)
		defer ui_select_destroy(ui)
		ui.view = &ui.no_view
		mu.init(&ui.ctx)
		ui.ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * 8}
		ui.ctx.text_height = proc(font: mu.Font) -> i32 {return 16}

		buf: [256]u8
		n := copy(buf[:], text)
		editing: proto.Msg_Id
		conv: proto.Conv_Id
		area: Text_Area
		c := Composer {
			buf     = buf[:],
			len     = &n,
			editing = &editing,
			conv    = &conv,
			area    = &area,
		}
		body, rect: mu.Rect
		frame :: proc(ui: ^UI, c: Composer, body, rect: ^mu.Rect) {
			ctx := &ui.ctx
			mu.begin(ctx)
			if mu.begin_window(ctx, "w", {0, 0, 200, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
				mu.layout_row(ctx, {-1}, composer_height(ui, c))
				composer_box(ui, c)
				if cnt := mu.get_container(ctx, fmt.tprintf("composer preview %d", c.thread));
				   cnt != nil {
					body^, rect^ = cnt.body, cnt.rect
				}
				mu.end_window(ctx)
			}
			mu.end(ctx)
		}
		// Written first, so the text area knows its width; then previewed.
		for _ in 0 ..< 2 {
			frame(ui, c, &body, &rect)
		}
		area.preview = true
		for _ in 0 ..< 3 {
			frame(ui, c, &body, &rect)
		}
		testing.expectf(t, rect.h > 0, "%q: no preview", text)
		testing.expectf(
			t,
			body.w == rect.w,
			"%q: the preview scrolls (body %v in %v)",
			text,
			body,
			rect,
		)
	}
}
