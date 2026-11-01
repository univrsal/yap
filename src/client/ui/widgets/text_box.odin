package widgets

import "client:ui/core"
import "client:platform"
import "client:render"
import mu "vendor:microui"

_ :: core // only used in the web build

// Every text box goes through text_box, which is mu.textbox plus a note of
// where it was laid out.
//
// A phone shows its keyboard only when one of the page's own text fields has
// the focus, and only if that happens while the tap is still being handled.
// The page can't wait a frame to see whether the tap landed on a text box. So
// each frame notes where its text boxes are, and the page asks about the tap
// there and then (see ui/touch_web.odin). A desktop build notes nothing.

text_box :: proc(env: ^core.Env, buf: []u8, textlen: ^int, opt := mu.Options{}) -> mu.Result_Set {
	ctx := &env.ctx
	// The same id mu.textbox would use, so ctx.last_id names the box
	// afterwards as it did.
	id := mu.get_id(ctx, uintptr(&buf[0]))
	r := mu.layout_next(ctx)
	when platform.WEB {
		append(
			&env.text_boxes,
			core.Text_Box{id, mu.intersect_rects(r, mu.get_clip_rect(ctx)), false, false},
		)
	}
	res := mu.textbox_raw(ctx, buf, textlen, id, r, opt)
	core.nav_control(ctx, id, r, textlen^)
	if ctx.hover_id == id {
		env.select.over_text = true // shows an I-beam over it (draw_frame)
	}
	return res
}

// password_box is a text box that shows an asterisk for every byte of its
// text, and won't copy or cut it.
//
// microui's text box has no such option, so the masking is done around it.
// While the box runs, the text is measured as asterisks (which is what the
// cursor, the selection and clicks are based on), and afterwards the text that
// it drew is overwritten with asterisks in microui's command list, before
// anything renders it.
password_box :: proc(env: ^core.Env, buf: []u8, textlen: ^int, opt := mu.Options{}) -> mu.Result_Set {
	ctx := &env.ctx
	if ctx.focus_id == mu.get_id(ctx, uintptr(&buf[0])) {
		ctx.key_pressed_bits -= {.C, .X}
	}

	text_width := ctx.text_width
	ctx.text_width = proc(font: mu.Font, text: string) -> i32 {
		return i32(len(text)) * render.ui_text_width(font, "*")
	}
	first := ctx.command_list.idx
	res := text_box(env, buf, textlen, opt)
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
