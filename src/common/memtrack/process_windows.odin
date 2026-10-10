#+build windows
package memtrack

import win "core:sys/windows"

/*
The working set and private bytes, as Task Manager shows them. Odin's
heap is the process heap (HeapAlloc), which can't be asked cheaply how
much of it is in use.
*/

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb:                         win.DWORD,
	PageFaultCount:             win.DWORD,
	PeakWorkingSetSize:         win.SIZE_T,
	WorkingSetSize:             win.SIZE_T,
	QuotaPeakPagedPoolUsage:    win.SIZE_T,
	QuotaPagedPoolUsage:        win.SIZE_T,
	QuotaPeakNonPagedPoolUsage: win.SIZE_T,
	QuotaNonPagedPoolUsage:     win.SIZE_T,
	PagefileUsage:              win.SIZE_T,
	PeakPagefileUsage:          win.SIZE_T,
	PrivateUsage:               win.SIZE_T,
}

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	K32GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^PROCESS_MEMORY_COUNTERS_EX, cb: win.DWORD) -> win.BOOL ---
	HeapCompact :: proc(heap: win.HANDLE, flags: win.DWORD) -> win.SIZE_T ---
}

@(private)
_process :: proc() -> (p: Process) {
	counters := PROCESS_MEMORY_COUNTERS_EX {
		cb = size_of(PROCESS_MEMORY_COUNTERS_EX),
	}
	if K32GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) {
		p.resident = int(counters.WorkingSetSize)
		p.resident_peak = int(counters.PeakWorkingSetSize)
		p.private = int(counters.PrivateUsage)
	}
	return
}

@(private)
_release_free :: proc() -> bool {
	HeapCompact(win.GetProcessHeap(), 0)
	return true
}
