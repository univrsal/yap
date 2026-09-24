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
