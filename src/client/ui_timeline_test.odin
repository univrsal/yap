#+build !wasi
package client

import "core:testing"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

@(private = "file")
Timeline_Test :: struct {
	ui:  ^UI,
	st:  UI_Timeline,
	key: conn.Timeline_Key,
	cnt: ^mu.Container, // the timeline's panel
}

// timeline_test_start makes a timeline of `count` messages, each a block of
// its own, all of them loaded.
@(private = "file")
timeline_test_start :: proc(count: int) -> ^Timeline_Test {
	tt := new(Timeline_Test)
	tt.ui = new(UI)
	tt.ui.view = &tt.ui.no_view
	mu.init(&tt.ui.ctx)
	tt.ui.ctx.text_width = proc(font: mu.Font, s: string) -> i32 {return i32(len(s)) * 8}
	tt.ui.ctx.text_height = proc(font: mu.Font) -> i32 {return 16}
	tt.key = {
		conv = 1,
	}
	tl := conn.View_Timeline {
		have_oldest = true,
		have_newest = true,
	}
	for i in 0 ..< count {
		append(
			&tl.messages,
			conn.View_Message {
				id     = proto.Msg_Id(i + 1),
				sender = 1,
				time   = proto.Unix_Ms(i * 600_000), // ten minutes apart: not merged
				kind   = .Text,
				text   = "hello there",
			},
		)
	}
	tt.ui.view.timelines[tt.key] = tl
	return tt
}

@(private = "file")
timeline_test_end :: proc(tt: ^Timeline_Test) {
	delete(tt.ui.view.timelines[tt.key].messages)
	delete(tt.ui.view.timelines)
	delete(tt.st.layouts)
	delete(tt.st.roots_asked)
	ui_select_destroy(tt.ui)
	free(tt.ui)
	free(tt)
}

@(private = "file")
timeline_test_frame :: proc(tt: ^Timeline_Test) {
	ctx := &tt.ui.ctx
	mu.begin(ctx)
	if mu.begin_window(ctx, "w", {0, 0, 400, 300}, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE}) {
		mu.layout_row(ctx, {-1}, -1)
		timeline(tt.ui, &tt.st, tt.key)
		tt.cnt = mu.get_container(ctx, "timeline") // TIMELINE_PANEL
		mu.end_window(ctx)
	}
	mu.end(ctx)
}

// Dragging the scrollbar of a timeline only a little taller than its panel
// up a pixel at a time, which moves it only a pixel or two, leaves the end
// rather than going back to it in the next frame. Dragging it back down to
// the end follows the end again.
@(test)
test_timeline_slow_drag_leaves_end :: proc(t: ^testing.T) {
	tt := timeline_test_start(8)
	defer timeline_test_end(tt)
	ctx := &tt.ui.ctx
	for _ in 0 ..< 3 {
		timeline_test_frame(tt)
	}
	at_end := tt.cnt.scroll.y
	testing.expect(t, at_end > 30)
	testing.expect(t, tt.st.follow)

	body := tt.cnt.body
	x, y := body.x + body.w + ctx.style.scrollbar_size / 2, body.y + body.h - 10
	mu.input_mouse_move(ctx, x, y)
	timeline_test_frame(tt)
	mu.input_mouse_down(ctx, x, y, .LEFT)
	timeline_test_frame(tt)
	for _ in 0 ..< 20 {
		y -= 1
		mu.input_mouse_move(ctx, x, y)
		timeline_test_frame(tt)
	}
	testing.expect(t, tt.cnt.scroll.y <= at_end - 20)
	testing.expect(t, !tt.st.follow)
	timeline_test_frame(tt) // and it stays there
	testing.expect(t, tt.cnt.scroll.y <= at_end - 20)

	for _ in 0 ..< 40 {
		y += 1
		mu.input_mouse_move(ctx, x, y)
		timeline_test_frame(tt)
	}
	testing.expect_value(t, tt.cnt.scroll.y, at_end)
	testing.expect(t, tt.st.follow)
}
