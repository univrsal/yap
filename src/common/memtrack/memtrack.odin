package memtrack

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

/*
Where the memory goes.

The allocator here sits on top of the heap and keeps a note of every
allocation that's still live, grouped by the line of code that made it
(the allocator is told that line anyway: #caller_location). The process
installs it as context.allocator before anything else, so everything in
Odin that allocates from the heap through the context is counted, on
every thread that's handed that context.

What it can't see is memory that doesn't go through it: C libraries'
own malloc (stb_image's decoded pictures, SQLite, libwebp, miniaudio,
the GPU driver), thread stacks, the program's code - and core:os's
scratch space, two arenas a thread that it takes from the heap itself
(4 MB each, once a thread has used it, though little of that is ever
touched, so it's in "heap in use" more than in RAM). And the heap
itself keeps memory that has been freed, for the next allocation,
rather than giving it back to the OS straight away. So a report sets
what's counted here beside what the OS and malloc say (process_*.odin):

	resident       what the OS has given the process, all of it
	heap in use    what malloc has handed out and not had back
	  counted      of that, what went through this allocator
	heap free      freed, but kept by malloc rather than given back

The notes are kept apart from the allocations, in maps keyed by
address, rather than in a header in front of each one: memory this
allocator didn't hand out (another thread's own context, a C library)
may be freed through it, and the other way round, and that's harmless -
it's just not counted.

-define:YAP_MEMTRACK=false leaves it out; the reports then have only
the process's numbers.
*/

ENABLED :: #config(YAP_MEMTRACK, true)

// A line of code that allocates, and what of it is live.
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
	overhead:    int, // the notes themselves, roughly
	sites:       int, // lines of code that have allocated
}

@(private)
Entry :: struct {
	size: int,
	site: u32,
}

// File_path's literal is the same string for every location in a file,
// so its address stands in for it.
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

// Where the temp allocators' blocks are counted: the line that happened
// to need a new block would say little.
@(private)
TEMP_SITE := runtime.Source_Code_Location {
	file_path = "temp allocator",
	procedure = "arena blocks",
}

/*
init starts counting, on top of `backing`, and returns the allocator to
put in the context: as early as possible, as what was allocated before
isn't counted. It also counts the calling thread's temp allocator's
blocks (thread_init). Without YAP_MEMTRACK it returns `backing`.
*/
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

// allocator is the counting allocator, once init has run; until then,
// and without YAP_MEMTRACK, the context's.
allocator :: proc() -> runtime.Allocator {
	when ENABLED {
		if g_tracker.backing.procedure != nil {
			return {procedure = tracker_proc}
		}
	}
	return context.allocator
}

/*
thread_init has the calling thread's temp allocator take its blocks
from the counting allocator, if it hasn't taken one yet: the temp
allocator keeps its first block for good, and it's as big as the first
thing asked of it, so it's worth seeing.
*/
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
		// Forgotten before it's freed: once it is, another thread may be
		// handed the same address.
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
			// Still where it was.
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
	// An address already noted was freed behind this allocator's back
	// (by a context that doesn't count); it's no longer that.
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

// totals is what's counted, overall.
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

// sites is every line of code that has allocated, in `allocator`,
// those with the most live first.
sites :: proc(allocator := context.temp_allocator) -> []Site {
	when !ENABLED {
		return nil
	} else {
		// Made outside the lock: `allocator` may be one that counts.
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

// What's live, by the file whose code allocated it.
File_Stat :: struct {
	file:  string, // short_path
	live:  int,
	count: int,
	peak:  int, // the sum of its lines' peaks: an upper bound
}

// by_file sums `sites` by file, in `allocator`, those with the most
// live first.
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

/*
short_path is a source file's path from where it starts to say
something: src/client/conn/messages.odin is conn/messages.odin, and
Odin's own core/strings/builder.odin stays that.
*/
short_path :: proc(path: string) -> string {
	p := path
	for sep in ([]string{"/src/", "\\src\\"}) {
		if i := strings.last_index(p, sep); i >= 0 {
			p = p[i + len(sep):]
			// Our own packages: client/, server/, common/ - the second
			// part is what tells them apart.
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

// bytes_string is n bytes for people: 512 B, 3.4 KB, 12.0 MB.
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
