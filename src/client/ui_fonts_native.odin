#+build !wasi
package client

import "client:render"
import "core:fmt"
import "core:strings"
import mu "vendor:microui"

// system_font_settings is the part of the user interface's settings about
// the system's fonts (render/sysfont.odin): whether the characters that the
// bundled fonts lack come from them rather than from Unifont, and which of
// them have been used so far.
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
	if !ui.settings.system_fonts {
		return
	}
	mu.layout_row(ctx, {-1})
	used := render.system_fonts_used(&ui.renderer)
	if len(used) == 0 {
		dim_note(ctx, "  None needed so far.")
	} else {
		dim_note(ctx, fmt.tprintf("  In use: %s", strings.join(used, ", ", context.temp_allocator)))
	}
}
