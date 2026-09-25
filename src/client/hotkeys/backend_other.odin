#+build !linux
#+build !windows
#+build !darwin
#+build !wasi
package hotkeys

// Nowhere else to look at the keys (the BSDs, say).

Backend :: struct {}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	return .Unavailable, "Global hotkeys aren't supported on this system."
}

backend_close :: proc(b: ^Backend) {}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {}

backend_status :: proc(b: ^Backend) -> (Status, string, bool) {
	return .Unavailable, "", false
}
