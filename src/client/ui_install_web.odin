#+build wasi
package client

// A page has nothing to install itself (see ui_install_native.odin): the
// browser installs it as an app, from web/manifest.webmanifest.

UI_Install :: struct {}

install_destroy :: proc(ui: ^UI) {}

install_settings :: proc(ui: ^UI) {}
