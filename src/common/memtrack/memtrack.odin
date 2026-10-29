package memtrack

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

// Tracks where the memory goes.
//
// The allocator here sits on top of the heap and keeps a record of every
// allocation that is still live, grouped by the line of code that made it
// (the allocator is told that line anyway through #caller_location). The
// process installs it as context.allocator before anything else, so every
// heap allocation made through the context is counted, on every thread that
// is handed that context.
//
// It can't see memory that doesn't go through it: the malloc of C libraries
// (libwebp, miniaudio, FFmpeg, the GPU driver), thread stacks and the
// program's code. SQLite and stb_image's decoded pictures are the exceptions,
// which external.odin counts under a site of their own. It also doesn't see
// core:os's scratch space, which is two arenas per thread that core:os takes
// from the heap itself (4 MB each once a thread has used it, although little
// of that is ever touched, so it shows up in "heap in use" more than in
// RAM). The heap also keeps freed memory around for the next allocation
// instead of returning it to the OS right away. A report therefore compares
// what is counted here with what the OS and malloc report (see
// process_*.odin):
//
//	resident       all memory the OS has given the process
//	heap in use    memory malloc has handed out and not got back
//	  counted      the part of that which went through this allocator
//	heap free      memory that was freed but is kept by malloc instead of
//	               being returned to the OS
//
// The records are kept apart from the allocations, in maps keyed by
// address, instead of in a header in front of each allocation. Memory that
// this allocator didn't hand out (from another thread's own context or a C
// library) may be freed through it, and the other way round. That is
// harmless; such memory is just not counted.
//
// Building with -define:YAP_MEMTRACK=false leaves the tracking out. The
// reports then contain only the process's numbers.

ENABLED :: #config(YAP_MEMTRACK, true)

// Site is a line of code that allocates, and how much of its memory is
// still live.
Site :: struct {
	loc:    runtime.Source_Code_Location,
	live:   int, // bytes
	count:  int, // allocations
	peak:   int, // most bytes live at once
	allocs: u64, // allocations ever made
}

Totals :: struct {
	live:        int, // bytes in allocations not yet freed
	count:       int, // how many allocations that is
	peak:        int, // most bytes live at once
	allocs:      u64, // allocations ever made
	alloc_bytes: u64, // and their bytes
	overhead:    int, // the tracking records themselves, roughly
	sites:       int, // lines of code that have allocated
}

@(private)
Entry :: struct {
	size: int,
	site: u32,
}

// The file_path literal is the same string for every location in a file,
// so its address is used to identify the file.
@(private)
Site_Key :: struct {
	file:   rawptr,
	line:   i32,
	column: i32,
}

@(private)
Tracker :: struct {
	mutex:      sync.Mutex,
	backing:    runtime.Allocator,
	live:       map[rawptr]Entry,
	sites:      [dynamic]Site,
	site_index: map[Site_Key]u32,
	totals:     Totals,
}

@(private)
g_tracker: Tracker

// The site that the temp allocators' blocks are counted under. The line
// that happened to need a new block would say little.
@(private)
TEMP_SITE := runtime.Source_Code_Location {
	file_path = "temp allocator",
	procedure = "arena blocks",
}

// init starts counting on top of `backing` and returns the allocator to put
// in the context. Call it as early as possible, because anything allocated
// before isn't counted. It also counts the blocks of the calling thread's
// temp allocator (see thread_init). Without YAP_MEMTRACK it returns
// `backing`.
init :: proc(backing := context.allocator) -> runtime.Allocator {
	when !ENABLED {
		return backing
	} else {
		t := &g_tracker
		t.backing = backing
		t.live = make(map[rawptr]Entry, backing)
		t.sites = make([dynamic]Site, backing)
		t.site_index = make(map[Site_Key]u32, backing)
		thread_init()
		return allocator()
	}
}

// allocator returns the counting allocator once init has run. Until then,
// and without YAP_MEMTRACK, it returns the context's allocator.
allocator :: proc() -> runtime.Allocator {
	when ENABLED {
		if g_tracker.backing.procedure != nil {
			return {procedure = tracker_proc}
		}
	}
	return context.allocator
}

// thread_init makes the calling thread's temp allocator take its blocks
// from the counting allocator, if it hasn't taken a block yet. The temp
// allocator keeps its first block forever, and that block is as big as the
// first thing asked of it, so it is worth tracking.
thread_init :: proc() {
	when ENABLED && !runtime.NO_DEFAULT_TEMP_ALLOCATOR {
		if g_tracker.backing.procedure == nil {
			return
		}
		data := &runtime.global_default_temp_allocator_data
		if context.temp_allocator.data == data && data.arena.curr_block == nil {
			data.arena.backing_allocator = {
				procedure = tracker_proc,
				data      = &TEMP_SITE,
			}
		}
	}
}

@(private)
tracker_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: runtime.Allocator_Error,
) {
	t := &g_tracker
	site_loc := loc if allocator_data == nil else (^runtime.Source_Code_Location)(allocator_data)^
	backing := t.backing

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		data, err = backing.procedure(backing.data, mode, size, alignment, nil, 0, loc)
		if err == nil && data != nil {
			sync.guard(&t.mutex)
			note_alloc(t, raw_data(data), len(data), site_loc)
		}

	case .Free:
		// The record is removed before the memory is freed, because once it
		// is freed another thread may be handed the same address.
		if old_memory != nil {
			sync.guard(&t.mutex)
			note_free(t, old_memory)
		}
		data, err = backing.procedure(backing.data, mode, 0, 0, old_memory, old_size, loc)

	case .Resize, .Resize_Non_Zeroed:
		old_entry: Entry
		had := false
		if old_memory != nil {
			sync.guard(&t.mutex)
			old_entry, had = t.live[old_memory]
			if had {
				note_free(t, old_memory)
			}
		}
		data, err = backing.procedure(
			backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
		sync.guard(&t.mutex)
		switch {
		case err != nil:
			// The allocation is still where it was.
			if had {
				restore(t, old_memory, old_entry)
			}
		case data != nil:
			note_alloc(t, raw_data(data), len(data), site_loc)
		}

	case .Free_All, .Query_Features, .Query_Info:
		data, err = backing.procedure(
			backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
	}
	return
}

@(private)
note_alloc :: proc(t: ^Tracker, p: rawptr, size: int, loc: runtime.Source_Code_Location) {
	key := Site_Key{raw_data(loc.file_path), loc.line, loc.column}
	index, found := t.site_index[key]
	if !found {
		index = u32(len(t.sites))
		append(&t.sites, Site{loc = loc})
		t.site_index[key] = index
	}
	// An address that is already recorded was freed behind this allocator's
	// back (by a context that doesn't count), so the old record is stale.
	if old, was := t.live[p]; was {
		forget(t, old)
	}
	t.live[p] = {size, index}

	s := &t.sites[index]
	s.live += size
	s.count += 1
	s.allocs += 1
	s.peak = max(s.peak, s.live)
	t.totals.live += size
	t.totals.count += 1
	t.totals.allocs += 1
	t.totals.alloc_bytes += u64(size)
	t.totals.peak = max(t.totals.peak, t.totals.live)
}

@(private)
note_free :: proc(t: ^Tracker, p: rawptr) {
	if e, found := t.live[p]; found {
		delete_key(&t.live, p)
		forget(t, e)
	}
}

@(private)
restore :: proc(t: ^Tracker, p: rawptr, e: Entry) {
	t.live[p] = e
	s := &t.sites[e.site]
	s.live += e.size
	s.count += 1
	t.totals.live += e.size
	t.totals.count += 1
}

@(private)
forget :: proc(t: ^Tracker, e: Entry) {
	s := &t.sites[e.site]
	s.live -= e.size
	s.count -= 1
	t.totals.live -= e.size
	t.totals.count -= 1
}

// totals returns the overall counts.
totals :: proc() -> Totals {
	when !ENABLED {
		return {}
	} else {
		t := &g_tracker
		sync.guard(&t.mutex)
		out := t.totals
		out.sites = len(t.sites)
		out.overhead =
			cap(t.live) * (size_of(rawptr) + size_of(Entry) + size_of(uintptr)) +
			cap(t.site_index) * (size_of(Site_Key) + size_of(u32) + size_of(uintptr)) +
			cap(t.sites) * size_of(Site)
		return out
	}
}

// sites returns every line of code that has allocated, allocated with
// `allocator` and sorted with the most live memory first.
sites :: proc(allocator := context.temp_allocator) -> []Site {
	when !ENABLED {
		return nil
	} else {
		// Allocated outside the lock because `allocator` may be one that
		// counts.
		t := &g_tracker
		out: []Site
		for {
			n: int
			{
				sync.guard(&t.mutex)
				n = len(t.sites)
			}
			out = make([]Site, n + 16, allocator)
			sync.guard(&t.mutex)
			if len(t.sites) <= len(out) {
				out = out[:copy(out, t.sites[:])]
				break
			}
		}
		slice.sort_by(out, proc(a, b: Site) -> bool {
			return a.live > b.live if a.live != b.live else a.allocs > b.allocs
		})
		return out
	}
}

// File_Stat is the live memory grouped by the file whose code allocated it.
File_Stat :: struct {
	file:  string, // short_path
	live:  int,
	count: int,
	peak:  int, // the sum of its lines' peaks, which is an upper bound
}

// by_file sums `sites` by file, allocated with `allocator` and sorted with
// the most live memory first.
by_file :: proc(sites: []Site, allocator := context.temp_allocator) -> []File_Stat {
	index := make(map[string]int, allocator = context.temp_allocator)
	out := make([dynamic]File_Stat, allocator)
	for s in sites {
		file := short_path(s.loc.file_path)
		i, found := index[file]
		if !found {
			i = len(out)
			index[file] = i
			append(&out, File_Stat{file = file})
		}
		f := &out[i]
		f.live += s.live
		f.count += s.count
		f.peak += s.peak
	}
	slice.sort_by(out[:], proc(a, b: File_Stat) -> bool {
		return a.live > b.live if a.live != b.live else a.peak > b.peak
	})
	return out[:]
}

// short_path shortens a source file's path to the meaningful part:
// src/client/conn/messages.odin becomes conn/messages.odin, and Odin's own
// core/strings/builder.odin stays as it is.
short_path :: proc(path: string) -> string {
	p := path
	for sep in ([]string{"/src/", "\\src\\"}) {
		if i := strings.last_index(p, sep); i >= 0 {
			p = p[i + len(sep):]
			// In our own packages (client/, server/, common/) the second
			// path component is what tells the files apart.
			for top in ([]string{"client", "server", "common"}) {
				if len(p) > len(top) && strings.has_prefix(p, top) {
					rest := p[len(top) + 1:]
					return rest if strings.contains_any(rest, "/\\") else p
				}
			}
			return p
		}
	}
	for root in ([]string{"/core/", "\\core\\", "/base/", "\\base\\", "/vendor/", "\\vendor\\"}) {
		if i := strings.last_index(p, root); i >= 0 {
			return p[i + 1:]
		}
	}
	return p
}

// bytes_string formats n bytes for people: 512 B, 3.4 KB, 12.0 MB.
bytes_string :: proc(n: int, allocator := context.temp_allocator) -> string {
	f := f64(n)
	switch {
	case n < 0:
		return fmt.aprintf("-%s", bytes_string(-n, context.temp_allocator), allocator = allocator)
	case n < 1024:
		return fmt.aprintf("%d B", n, allocator = allocator)
	case n < 1024 * 1024:
		return fmt.aprintf("%.1f KB", f / 1024, allocator = allocator)
	case n < 1024 * 1024 * 1024:
		return fmt.aprintf("%.1f MB", f / (1024 * 1024), allocator = allocator)
	}
	return fmt.aprintf("%.2f GB", f / (1024 * 1024 * 1024), allocator = allocator)
}
