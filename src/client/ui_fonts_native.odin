#+build !wasi
package client

import "client:render"
import "core:fmt"
import "core:strings"
import mu "vendor:microui"

// system_font_settings is the part of the user interface's settings about
// the system's fonts (render/sysfont.odin) and emoji
// (render/sysemoji_native.odin): whether the characters that the bundled
// fonts lack come from them rather than from Unifont, and which of them have
// been used so far; whether emoji are the system's rather than the bundled
// ones, and which font they come from.
system_font_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .CHANGE in
	   checkbox_noted(
		   ui,
		   "Use the system's fonts",
		   "for characters the built-in fonts don't have",
		   &ui.settings.system_fonts,
	   ) {
		save_settings(ui)
		ui_redraw(ui)
	}
	if ui.settings.system_fonts {
		mu.layout_row(ctx, {-1})
		used := render.system_fonts_used(&ui.renderer)
		if len(used) == 0 {
			dim_note(ctx, "  None needed so far.")
		} else {
			dim_note(ctx, fmt.tprintf("  In use: %s", strings.join(used, ", ", context.temp_allocator)))
		}
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in checkbox(ctx, "Use the system's emoji", &ui.settings.system_emoji) {
		save_settings(ui)
		ui_redraw(ui)
	}
	if ui.settings.system_emoji {
		mu.layout_row(ctx, {-1})
		if name := render.system_emoji_font(&ui.renderer); name != "" {
			dim_note(ctx, fmt.tprintf("  From %s; the built-in ones where it has none.", name))
		} else {
			dim_note(ctx, "  The system has no emoji font that can be used, so the built-in ones are.")
		}
	}
}
