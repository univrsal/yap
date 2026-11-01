#+build wasi
package ui

// A page can't install itself (see ui/install_native.odin). Instead, the
// browser installs it as an app from web/manifest.webmanifest.

UI_Install :: struct {}

install_destroy :: proc(ui: ^UI) {}

install_settings :: proc(ui: ^UI) {}
