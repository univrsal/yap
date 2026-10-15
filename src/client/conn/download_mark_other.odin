#+build !windows
#+build !darwin
#+build !wasi
package conn

// mark_downloaded does nothing here because Linux and the BSDs have no standard
// way to mark files as downloaded from the internet (see
// download_mark_windows.odin and download_mark_darwin.odin).
mark_downloaded :: proc(path: string) {}
