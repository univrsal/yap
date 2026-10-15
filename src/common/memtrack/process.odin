package memtrack

// Process holds what the OS and malloc report about the process, to
// compare with what is counted here. A value of 0 means it isn't known on
// this platform.
Process :: struct {
	resident:      int, // in RAM now (RSS, the working set)
	resident_peak: int, // the highest it has been
	private:       int, // memory belonging to the process alone, swapped out or not (Windows' private bytes, macOS' footprint)
	heap_known:    bool, // heap_in_use and heap_free are known
	heap_in_use:   int, // memory malloc has handed out and not got back
	heap_free:     int, // memory that was freed but is kept by malloc instead of being returned to the OS
	wasm_memory:   int, // a web build's linear memory, which only ever grows
}

// process queries the OS and malloc.
process :: proc() -> Process {
	return _process()
}

// release_free asks malloc to return the freed memory it is holding on to
// (which is what heap_free measures) to the OS. It returns false where
// that isn't possible. The counts kept here don't change either way, but
// the process's do.
release_free :: proc() -> bool {
	return _release_free()
}
