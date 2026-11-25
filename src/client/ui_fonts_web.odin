#+build wasi
package client

// A page can't use the system's fonts (render/sysfont_web.odin), so there is
// nothing to set.
system_font_settings :: proc(ui: ^UI) {}
