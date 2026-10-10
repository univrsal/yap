package memtrack

/*
What the OS and malloc say about the process, beside what's counted
here. A number that's 0 isn't known on this platform.
*/
Process :: struct {
	resident:      int, // in RAM now (RSS, the working set)
	resident_peak: int, // the most it has been
	private:       int, // the process's own, swapped out or not: Windows' private bytes, macOS' footprint
	heap_known:    bool, // heap_in_use and heap_free are known
	heap_in_use:   int, // malloc's: handed out and not had back
	heap_free:     int, // freed, but kept by malloc rather than given back to the OS
	wasm_memory:   int, // a web build's linear memory: it only ever grows
}

// process asks the OS and malloc.
process :: proc() -> Process {
	return _process()
}

/*
release_free asks malloc to give the OS back what it's keeping that's
been freed, which is what heap_free is. False where there's no way to;
the counts here don't change either way, the process's do.
*/
release_free :: proc() -> bool {
	return _release_free()
}
