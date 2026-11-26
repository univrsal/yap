#+build wasi
package client

import "client:render"
import "core:fmt"
import mu "vendor:microui"

// system_font_settings is the part of the user interface's settings about
// the browser's fonts (render/sysglyph_web.odin) and emoji
// (render/sysemoji_web.odin): whether the characters that the bundled fonts
// lack are drawn with the fonts the browser has for them rather than from
// Unifont, and which have been used so far; and whether emoji are the
// browser's rather than the bundled ones.
system_font_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .CHANGE in
	   checkbox_noted(
		   ui,
		   "Use the browser's fonts",
		   "for characters the built-in fonts don't have",
		   &ui.settings.system_fonts,
	   ) {
		save_settings(ui)
		ui_redraw(ui)
	}
	if ui.settings.system_fonts {
		mu.layout_row(ctx, {-1})
		if len(render.system_fonts_used(&ui.renderer)) == 0 {
			dim_note(ctx, "  None needed so far.")
		} else {
			dim_note(ctx, "  In use, where the browser has a font; Unifont otherwise.")
		}
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in checkbox(ctx, "Use the browser's emoji", &ui.settings.system_emoji) {
		save_settings(ui)
		ui_redraw(ui)
	}
	if ui.settings.system_emoji {
		mu.layout_row(ctx, {-1})
		if name := render.system_emoji_font(&ui.renderer); name != "" {
			dim_note(ctx, fmt.tprintf("  From %s; the built-in ones where it has none.", name))
		} else {
			dim_note(ctx, "  The browser has no color emoji font, so the built-in ones are used.")
		}
	}
}
