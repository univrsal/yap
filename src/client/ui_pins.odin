package client

import "core:fmt"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "common:proto"

// The pinned messages of the conversation being looked at, in a floating
// window of their own, opened by the pin button in the conversation's header.
// The newest pin is first. Clicking a pin makes the timeline jump to that
// message (UI_Timeline.jump_to): the page around it is fetched if it isn't in
// the loaded window, and the message is scrolled to and highlighted for a
// moment.
//
// The network side fetches the pins when the window opens or shows another
// conversation's, and again when one of them changes.

UI_Pins :: struct {
	open:   bool,
	placed: bool, // whether its position has been set since it was opened
	// The conversation whose pins were requested.
	asked:  proto.Conv_Id,
}

@(private = "file")
PINS_WINDOW :: "Pinned messages"

// pins_button is the header's pin button, which opens and closes the window.
// Call with the View locked.
pins_button :: proc(ui: ^UI) {
	if .SUBMIT in
	   icon_button(
		   ui,
		   "pins",
		   .Pin,
		   "Hide the pinned messages" if ui.pins.open else "Pinned messages",
		   theme.chat_name if ui.pins.open else {},
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
		command(ui, conn.Pins_Command{conv = v.viewing})
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
	keep_in_window(ui) // dragged: kept below the top bar, on screen
	defer mu.end_window(ctx)

	pins := &v.pins
	if pins.conv != v.viewing || (pins.loading && len(pins.messages) == 0) {
		spinner_row(ui)
		return
	}
	if len(pins.messages) == 0 {
		mu.layout_row(ctx, {-1})
		dim_label(ctx, "Nothing is pinned here.")
		return
	}
	for m, i in pins.messages {
		mu.push_id(ctx, uintptr(m.id))
		defer mu.pop_id(ctx)
		go := [?]Card_Button{{"go", .Pop_Out, "Go to the message", {}}}
		if message_card(ui, m, nil, go[:]) == 0 {
			ui.timeline.jump_to = m.id
			ui.timeline.jump_asked = false
			ui.timeline.jump_conv = 0
		}
		if i < len(pins.messages) - 1 {
			mu.layout_row(ctx, {-1}, 1)
			mu.draw_rect(ctx, mu.layout_next(ctx), theme.divider)
		}
	}
}

// A button beside a message_card: an icon button.
Card_Button :: struct {
	id:    string,
	icon:  render.Icon,
	hint:  string,
	color: mu.Color, // the icon's, if set
}

// message_card draws a message in a dialog's list (pins, bookmarks) as the
// chat draws it: the author's name in their colour and the time dimmed after
// it, then the text with its markdown, mentions and emoji. Pictures aren't
// drawn, files are named. Under it go the dim lines of `notes`, and beside
// the header the icon `buttons`, one under the other. It returns the index of
// the button that was pressed, or -1. Call with the View locked.
message_card :: proc(
	ui: ^UI,
	m: conn.View_Message,
	notes: []string,
	buttons: []Card_Button,
) -> (
	pressed: int,
) {
	pressed = -1
	ctx := &ui.ctx
	v := ui.view
	name := "someone"
	if acc, ok := v.accounts[m.sender]; ok {
		name = acc.display
	}
	color := author_color(v, m.sender)
	if .Persona in m.flags {
		name = m.persona.name
		color = theme.chat_name
	}
	stamp := chat_time(ui, proto.Unix_Time(m.time / 1000))
	at := len(name) + 2
	ui.header_sender, ui.header_bot = 0, 0
	ui.header_name = {0, len(name)}
	ui.header_time = {at, at + len(stamp)}
	defer ui.header_name, ui.header_time = {}, {}
	header := fmt.tprintf(
		"%s  %s%s",
		name,
		stamp,
		"  (edited)" if m.edited != 0 && .Deleted not_in m.flags else "",
	)

	text: Rich
	text_color := ctx.style.colors[.TEXT]
	switch {
	case .Deleted in m.flags:
		text, text_color = rich_plain("message deleted"), theme.dim
	case m.kind == .File:
		text = rich_plain(fmt.tprintf("the file %s", m.text))
	case m.kind == .Text:
		if m.text == "" && len(m.files) > 0 {
			text = rich_plain(files_said(m.files))
		} else {
			text = message_rich(ui, m.text)
		}
	case:
		text, text_color = rich_plain("a note about the conversation"), theme.dim
	}

	// The message in the first cell, which grows with it, and the buttons in
	// the second, starting level with the header.
	button := render.ICON_SIZE + 2 * ctx.style.padding
	mu.layout_row(ctx, {-(button + ctx.style.spacing), -1}, 0)
	mu.layout_begin_column(ctx)
	chat_message(ui, header, color, &text, text_color, false, i64(m.id) * ITEMS_PER_MESSAGE)
	for note in notes {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, note, wrap_text)
	}
	mu.layout_end_column(ctx)
	mu.layout_begin_column(ctx)
	mu.layout_row(ctx, {-1}, button)
	for b, i in buttons {
		if .SUBMIT in icon_button(ui, b.id, b.icon, b.hint, b.color) {
			pressed = i
		}
	}
	mu.layout_end_column(ctx)
	return
}

// How long a message that was jumped to stays highlighted.
JUMP_HIGHLIGHT :: 2 * time.Second
