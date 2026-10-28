package mattermost

import "core:slice"
import "core:testing"

@(test)
test_post_reader :: proc(t: ^testing.T) {
	s, err := scan({dir = SAMPLE, team = "acme"})
	testing.expect_value(t, err, "")
	if s == nil {
		return
	}
	defer scan_destroy(s)
	refs := s.posts[:]
	slice.sort_by(refs, proc(x, y: Post_Ref) -> bool {
		if x.time != y.time {
			return x.time < y.time
		}
		if x.offset != y.offset {
			return x.offset < y.offset
		}
		return x.reply < y.reply
	})

	// Read in time order with the usual budget, and again with one that keeps
	// nothing for long, so that threads are read from the file again and again.
	Seen :: struct {
		user, message, type: string,
		create_at:           i64,
		reactions:           int,
		replies:             int,
	}
	read_all :: proc(t: ^testing.T, s: ^Scan, refs: []Post_Ref, budget: int) -> []Seen {
		r: Post_Reader
		testing.expect_value(t, post_reader_open(&r, s, context.allocator), "")
		defer post_reader_close(&r)
		if budget > 0 {
			r.budget = budget
		}
		seen := make([]Seen, len(refs))
		for ref, i in refs {
			body, ok := post_read(&r, ref)
			testing.expect(t, ok)
			seen[i] = {
				user      = string(clone_string(body.user)),
				message   = clone_string(body.message),
				type      = clone_string(body.type),
				create_at = body.create_at,
				reactions = len(body.reactions),
				replies   = body.replies,
			}
		}
		return seen
	}
	free_seen :: proc(seen: []Seen) {
		for x in seen {
			delete(x.user)
			delete(x.message)
			delete(x.type)
		}
		delete(seen)
	}
	normal := read_all(t, s, refs, 0)
	defer free_seen(normal)
	tight := read_all(t, s, refs, 1)
	defer free_seen(tight)
	testing.expect_value(t, len(normal), len(refs))
	for x, i in normal {
		testing.expectf(t, x == tight[i], "post %d differs: %v and %v", i, x, tight[i])
	}
	// A thread's replies are the replies' own fields, not the first post's.
	replies := 0
	for ref, i in refs {
		if ref.reply >= 0 {
			replies += 1
			testing.expect_value(t, normal[i].replies, 0)
		}
	}
	testing.expect_value(t, replies, 5)
	// Nothing is left over in the reader once everything was read: the lines
	// with replies were let go (the budget aside, which counts what is kept).
	r: Post_Reader
	testing.expect_value(t, post_reader_open(&r, s, context.allocator), "")
	for ref in refs {
		_, _ = post_read(&r, ref)
	}
	testing.expect(t, len(r.cache) <= 1) // the last one, dropped by the next read
	post_reader_close(&r)
}

@(private = "file")
clone_string :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}
