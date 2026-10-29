package mattermost

import "core:encoding/json"
import "core:mem"
import "core:os"

// Pass 2 of the importer reads the posts again, in time order, by where pass 1
// found them. A post with replies is one line that is needed for each of them,
// and they come at different times, so a line that has been read is kept while
// there are posts left in it, within a budget; a line that is still needed
// after having been dropped is read again.

// Post_Reader reads the posts that pass 1 made references to.
Post_Reader :: struct {
	file:        ^os.File,
	// The lines with replies that are kept, by where they start.
	cache:       map[i64]^Cached_Line,
	// What is left to read of the lines that have replies: how many references
	// there are to each, and once it is none, the line is dropped.
	remaining:   map[i64]int,
	order:       [dynamic]i64, // the order the lines were read in, to drop the oldest
	used:        int, // bytes that the kept lines have taken
	budget:      int,
	// The line that the last read used up, which is dropped at the next one.
	finished:    bool,
	finished_at: i64,
	// A line without replies, which is dropped at the next read.
	scratch:     Cached_Line,
	allocator:   Allocator,
}

@(private = "file")
Cached_Line :: struct {
	arena:     mem.Dynamic_Arena,
	size:      int,
	post:      Post,
	direct:    Direct_Post,
	is_direct: bool,
	has:       bool,
}

// The most that kept lines take. A thread of a thousand replies is a few
// hundred kilobytes.
READER_BUDGET :: 64 * 1024 * 1024

// post_reader_open opens import.jsonl of an export for pass 2.
post_reader_open :: proc(r: ^Post_Reader, s: ^Scan, allocator: Allocator) -> (err: string) {
	file, open_err := os.open(join(s.dir, IMPORT_FILE))
	if open_err != nil {
		return "could not open import.jsonl again"
	}
	r^ = {
		file      = file,
		cache     = make(map[i64]^Cached_Line, allocator),
		remaining = make(map[i64]int, allocator),
		order     = make([dynamic]i64, allocator),
		budget    = READER_BUDGET,
		allocator = allocator,
	}
	// A line that has replies has a reference for the post and for each reply.
	threaded := make(map[i64]bool, context.temp_allocator)
	for ref in s.posts {
		if ref.reply >= 0 {
			threaded[ref.offset] = true
		}
	}
	for ref in s.posts {
		if ref.offset in threaded {
			r.remaining[ref.offset] += 1
		}
	}
	return ""
}

post_reader_close :: proc(r: ^Post_Reader) {
	for _, line in r.cache {
		mem.dynamic_arena_destroy(&line.arena)
		free(line, r.allocator)
	}
	delete(r.cache)
	delete(r.remaining)
	delete(r.order)
	line_free(&r.scratch)
	if r.file != nil {
		os.close(r.file)
	}
	r^ = {}
}

@(private = "file")
line_free :: proc(l: ^Cached_Line) {
	if l.has {
		mem.dynamic_arena_destroy(&l.arena)
	}
	l^ = {}
}

// post_read returns what the reference points at: the post's own fields or its
// reply's, with strings that stay valid until the next call. `ok` is false if
// the line can't be read.
post_read :: proc(r: ^Post_Reader, ref: Post_Ref) -> (body: Post_Body, ok: bool) {
	// A line that was used up by the last call is let go now, not then, because
	// the strings of what that call returned are in it.
	if r.finished {
		drop(r, r.finished_at)
		r.finished = false
	}
	line, found := r.cache[ref.offset]
	if !found {
		line = read_cached(r, ref) or_return
	}
	if left, tracked := r.remaining[ref.offset]; tracked {
		r.remaining[ref.offset] = left - 1
		if left - 1 <= 0 {
			r.finished, r.finished_at = true, ref.offset
		}
	}
	switch {
	case ref.reply >= 0 && line.is_direct:
		return body_of_reply(line.direct.replies[ref.reply]), true
	case ref.reply >= 0:
		return body_of_reply(line.post.replies[ref.reply]), true
	case line.is_direct:
		return body_of_direct(line.direct), true
	}
	return body_of_post(line.post), true
}

@(private = "file")
read_cached :: proc(r: ^Post_Reader, ref: Post_Ref) -> (line: ^Cached_Line, ok: bool) {
	text, read := line_at(r.file, ref.offset, int(ref.length), context.temp_allocator)
	if !read {
		return
	}
	line_free(&r.scratch)
	line = new(Cached_Line, r.allocator)
	mem.dynamic_arena_init(
		&line.arena,
		block_size = max(len(text) * 4, 8192),
		out_band_size = 1 << 20,
	)
	line.has = true
	line.size = len(text)
	allocator := mem.dynamic_arena_allocator(&line.arena)
	err: json.Unmarshal_Error
	if ref.direct {
		w: Direct_Post_Wrapper
		err = json.unmarshal(text, &w, allocator = allocator)
		line.direct, line.is_direct = w.direct_post, true
	} else {
		w: Post_Wrapper
		err = json.unmarshal(text, &w, allocator = allocator)
		line.post = w.post
	}
	if err != nil {
		mem.dynamic_arena_destroy(&line.arena)
		free(line, r.allocator)
		return nil, false
	}
	if ref.offset in r.remaining {
		// Kept for the replies that are left.
		r.cache[ref.offset] = line
		append(&r.order, ref.offset)
		r.used += line.size * 4
		for r.used > r.budget && len(r.order) > 1 {
			oldest := r.order[0]
			if oldest == ref.offset {
				break
			}
			drop(r, oldest)
		}
	} else {
		r.scratch = line^
		free(line, r.allocator)
		line = &r.scratch
	}
	return line, true
}

@(private = "file")
drop :: proc(r: ^Post_Reader, offset: i64) {
	line, found := r.cache[offset]
	if !found {
		return
	}
	delete_key(&r.cache, offset)
	for o, i in r.order {
		if o == offset {
			ordered_remove(&r.order, i)
			break
		}
	}
	r.used -= line.size * 4
	mem.dynamic_arena_destroy(&line.arena)
	free(line, r.allocator)
}
