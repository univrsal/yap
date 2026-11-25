#+build !linux
#+build !freebsd
#+build !openbsd
#+build !netbsd
package client

// Dictionaries are only downloaded where spelling is checked with Hunspell
// (ui_spell_download.odin). Elsewhere the system's checker has its own.

spell_dirs :: proc() -> []string {
	return nil
}

spell_download_step :: proc(ui: ^UI) {}

spell_download_settings :: proc(ui: ^UI) {}

spell_download_destroy :: proc(ui: ^UI) {}
