#+build !linux
#+build !openbsd
#+build !windows
#+build !darwin
#+build !wasi
package hotkeys

// There is no way to read the key state on other systems (e.g. the other BSDs).

Backend :: struct {}

backend_open :: proc(b: ^Backend) -> (Status, string) {
	return .Unavailable, "Global hotkeys aren't supported on this system."
}

backend_close :: proc(b: ^Backend) {}

backend_poll :: proc(b: ^Backend, s: ^State, wanted: Keys) {}

backend_status :: proc(b: ^Backend) -> (Status, string, bool) {
	return .Unavailable, "", false
}
