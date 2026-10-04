#+build !windows
#+build !darwin
#+build !wasi
package conn

// mark_downloaded: Linux and the BSDs have no mark for what came from
// the internet (download_mark_windows.odin, download_mark_darwin.odin).
mark_downloaded :: proc(path: string) {}
