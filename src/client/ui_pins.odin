package client

import "core:fmt"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
The pinned messages of the conversation being looked at, in a floating
window of their own, opened by the pin button in the conversation's
header. The newest pin is first. Clicking one has the timeline jump to
it (UI_Timeline.jump_to): the page around it is fetched if it isn't in
the window, and it's scrolled to and lit up for a moment.

The network side fetches the pins when the window opens, or shows
another conversation's, and again when one of them changes.
*/

UI_Pins :: struct {
	open:   bool,
	placed: bool, // its place has been set since it opened
	// The conversation whose pins were asked for.
	asked:  proto.Conv_Id,
}

@(private = "file")
PINS_WINDOW :: "Pinned messages"

// pins_button is the header's pin button, which opens and closes the
// window. Call with the View locked.
pins_button :: proc(ui: ^UI) {
	if .SUBMIT in
	   icon_button(
		   ui,
		   "pins",
		   .Pin,
		   "Hide the pinned messages" if ui.pins.open else "Pinned messages",
		   CHAT_NAME_COLOR if ui.pins.open else {},
	   ) {
		ui.pins.open = !ui.pins.open
		ui.pins.placed = false
		ui.pins.asked = 0
	}
}

pins_window :: proc(ui: ^UI, window_w, window_h: i32) {
	p := &ui.pins
	if !p.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.viewing == 0 || v.status != .Connected {
		p.open = false
		return
	}
	if p.asked != v.viewing {
		p.asked = v.viewing
		conn.push_command(&ui.session.client.commands, conn.Pins_Command{conv = v.viewing})
	}
	if !p.placed {
		p.placed = true
		w := clamp(window_w / 3, 260, 420)
		h := clamp(window_h - 120, 200, 600)
		if cnt := mu.get_container(ctx, PINS_WINDOW); cnt != nil {
			cnt.rect = {window_w - w - 20, 60, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, PINS_WINDOW, {}) {
		p.open = false // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)

	pins := &v.pins
	mu.layout_row(ctx, {-1})
	switch {
	case pins.conv != v.viewing || (pins.loading && len(pins.messages) == 0):
		with_text_color(ctx, CHAT_DIM_COLOR, "Loading...", label_proc)
		return
	case len(pins.messages) == 0:
		with_text_color(ctx, CHAT_DIM_COLOR, "Nothing is pinned here.", label_proc)
		return
	}
	for m, i in pins.messages {
		mu.push_id(ctx, uintptr(m.id))
		defer mu.pop_id(ctx)
		name := "someone"
		if acc, ok := v.accounts[m.sender]; ok {
			name = acc.display
		}
		mu.layout_row(ctx, {-70, -1})
		with_text_color(
			ctx,
			author_color(v, m.sender),
			fmt.tprintf("%s  %s", chat_time(ui, proto.Unix_Time(m.time / 1000)), name),
			label_proc,
		)
		if .SUBMIT in stable_button(ctx, "go", "Go to") {
			ui.timeline.jump_to = m.id
			ui.timeline.jump_asked = false
			ui.timeline.jump_conv = 0
		}
		mu.layout_row(ctx, {-1})
		shown, _ := conn.mentions_display(m.text, v.accounts, v.me)
		text := conn.markdown_plain(shown)
		#partial switch m.kind {
		case .Image:
			text = fmt.tprintf("a picture, %dx%d", m.image.width, m.image.height)
		case .File:
			text = fmt.tprintf("the file %s", m.text)
		}
		mu.text(ctx, conn.one_line(text))
		if i < len(pins.messages) - 1 {
			mu.layout_row(ctx, {-1}, 1)
			mu.draw_rect(ctx, mu.layout_next(ctx), {70, 70, 70, 255})
		}
	}
}

// How long a message jumped to stays lit.
JUMP_HIGHLIGHT :: 2 * time.Second
