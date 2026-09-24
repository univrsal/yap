package client

import mu "vendor:microui"

/*
Every text box goes through text_box, which is mu.textbox plus a note
of where it was laid out.

A phone shows its keyboard only when one of the page's own text fields
has the focus, and only if that happens while the tap is still being
handled - the page can't wait a frame to see whether the tap landed on
a text box. So each frame notes where its text boxes are, and the page
asks about the tap there and then (see ui_touch_web.odin). A desktop
build notes nothing.
*/

Text_Box :: struct {
	id:   mu.Id,
	rect: mu.Rect, // as visible: clipped to its container
}

text_box :: proc(ui: ^UI, buf: []u8, textlen: ^int, opt := mu.Options{}) -> mu.Result_Set {
	ctx := &ui.ctx
	// The same id mu.textbox would use, so ctx.last_id names the box
	// afterwards as it did.
	id := mu.get_id(ctx, uintptr(&buf[0]))
	r := mu.layout_next(ctx)
	when WEB {
		append(&ui.text_boxes, Text_Box{id, mu.intersect_rects(r, mu.get_clip_rect(ctx))})
	}
	return mu.textbox_raw(ctx, buf, textlen, id, r, opt)
}

/*
password_box is a text box that shows an asterisk for every byte of its
text, and won't copy or cut it.

microui's text box has no such option, so it's masked around it: while
the box runs, text is measured as asterisks (which is where the cursor,
the selection and clicks land), and afterwards the text it drew is
overwritten with asterisks in microui's command list, before anything
renders it.
*/
password_box :: proc(ui: ^UI, buf: []u8, textlen: ^int, opt := mu.Options{}) -> mu.Result_Set {
	ctx := &ui.ctx
	if ctx.focus_id == mu.get_id(ctx, uintptr(&buf[0])) {
		ctx.key_pressed_bits -= {.C, .X}
	}

	text_width := ctx.text_width
	ctx.text_width = proc(font: mu.Font, text: string) -> i32 {
		return i32(len(text)) * ui_text_width(font, "*")
	}
	first := ctx.command_list.idx
	res := text_box(ui, buf, textlen, opt)
	ctx.text_width = text_width

	for at := first; at < ctx.command_list.idx; {
		cmd := (^mu.Command)(&ctx.command_list.items[at])
		if text, ok := cmd.variant.(^mu.Command_Text); ok {
			for i in 0 ..< len(text.str) {
				([^]u8)(raw_data(text.str))[i] = '*'
			}
		}
		at += cmd.size
	}
	return res
}
