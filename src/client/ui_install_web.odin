#+build wasi
package client

// A page has nothing to install (see ui_install_native.odin).

UI_Install :: struct {}

install_destroy :: proc(ui: ^UI) {}

install_settings :: proc(ui: ^UI) {}
