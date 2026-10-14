package proto

import "core:encoding/endian"
import "core:time"

/*
Video_Window puts one sharer's frames back together for the decoder, and
says which fragments to ask the server for again (Nack).

It collects up to VIDEO_WINDOW frames at once, so a fragment lost or
late in one frame doesn't stop the next from being collected, and hands
them out complete and in order (video_window_pop). A frame with
something missing is asked for again: once after REORDER_WAIT (a gap
younger than that is as likely reordering as loss), once more after
NACK_RETRY if that didn't bring it, and given up on after another
NACK_RETRY. What's missing is whatever lies before the newest fragment
of the frame seen so far, or the rest of the frame once a newer frame
has come or nothing has for TAIL_WAIT; of a frame of which nothing came
at all (its number skipped), everything.

A frame given up on, or pushed out of the window by newer ones, means
what follows would decode wrong, so from then on `broken` is set and
only a keyframe gets through, as with the server's keyframe requests.
It starts out broken, as there's nothing to decode against yet.

Without a server that answers Nacks (the main loop doesn't; only the
media link does, server/media.odin) a loss is given up on once it's
REORDER_WAIT old: waiting longer would only hold the keyframe request
up.

It's large (VIDEO_WINDOW frames' bookkeeping), so allocate it.
*/

VIDEO_WINDOW :: 8
REORDER_WAIT :: 10 * time.Millisecond
NACK_RETRY :: 80 * time.Millisecond
TAIL_WAIT :: 20 * time.Millisecond
// Fragments a Nack can name.
NACK_SPAN :: 64
// Nacks a frame may send in one round: enough for the biggest frame.
@(private = "file")
MAX_NACKS_A_ROUND :: (MAX_VIDEO_FRAGMENTS + NACK_SPAN - 1) / NACK_SPAN

/*
Nack asks the server, over the media link, for fragments of a frame it
passed on to us again:

	client -> server  Nack  [kind][sharer u32][frame u32][first u16][missing u64]

bit i of `missing` is fragment first + i. The server sends what of them
it still has (it keeps half a second's worth) as Video, as before.
*/
NACK_SIZE :: 1 + 4 + 4 + 2 + 8

Video_Nack :: struct {
	frame:   u32,
	first:   int,
	missing: u64,
}

encode_nack :: proc(out: ^[NACK_SIZE]u8, sharer: User_Num, n: Video_Nack) -> []u8 {
	out[0] = u8(Message_Kind.Nack)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	endian.unchecked_put_u32le(out[5:], n.frame)
	endian.unchecked_put_u16le(out[9:], u16(n.first))
	endian.unchecked_put_u64le(out[11:], n.missing)
	return out[:]
}

@(require_results)
decode_nack :: proc(pt: []u8) -> (sharer: User_Num, n: Video_Nack, ok: bool) {
	if len(pt) != NACK_SIZE {
		return
	}
	sharer = User_Num(endian.unchecked_get_u32le(pt[1:]))
	n = {
		frame   = endian.unchecked_get_u32le(pt[5:]),
		first   = int(endian.unchecked_get_u16le(pt[9:])),
		missing = endian.unchecked_get_u64le(pt[11:]),
	}
	return sharer, n, n.first < MAX_VIDEO_FRAGMENTS
}

@(private = "file")
Window_Slot :: struct {
	used:     bool,
	frame:    u32,
	ts:       u32,
	key:      bool,
	codec:    Video_Codec,
	count:    int, // 0 while none of it has come
	received: int,
	size:     int,
	newest:   int, // the highest index come so far, -1 for none
	have:     [MAX_VIDEO_FRAGMENTS]bool,
	buf:      [dynamic]u8,
	last_at:  time.Tick, // its last fragment
	gap_at:   time.Tick, // when it was first seen to lack something
	rounds:   int, // Nack rounds sent
	nack_at:  time.Tick,
	gave_up:  bool,
}

Video_Window :: struct {
	slots:     [VIDEO_WINDOW]Window_Slot,
	started:   bool,
	next:      u32, // the frame to hand out next
	newest:    u32, // the newest frame seen
	broken:    bool,
	// For the log.
	nacked:    int, // fragments asked for again
	recovered: int, // frames that came whole after being asked for
	given_up:  int, // frames given up on
}

video_window_reset :: proc(w: ^Video_Window) {
	for &s in w.slots {
		clear_slot(&s)
	}
	w.started, w.broken = false, true
}

video_window_destroy :: proc(w: ^Video_Window) {
	for &s in w.slots {
		delete(s.buf)
	}
}

@(private = "file")
clear_slot :: proc(s: ^Window_Slot) {
	buf := s.buf
	clear(&buf)
	s^ = {}
	s.buf = buf
	s.newest = -1
}

// slot_of is frame `frame`'s slot, readied for it if it held another.
@(private = "file")
slot_of :: proc(w: ^Video_Window, frame: u32) -> ^Window_Slot {
	s := &w.slots[frame % VIDEO_WINDOW]
	if !s.used || s.frame != frame {
		clear_slot(s)
		s.used, s.frame = true, frame
	}
	return s
}

@(private = "file")
complete :: proc(s: ^Window_Slot) -> bool {
	return s.count > 0 && s.received == s.count
}

/*
video_window_add feeds in a fragment that came at `now`. What it
completes comes out of video_window_pop, in order.
*/
video_window_add :: proc(w: ^Video_Window, f: Video_Fragment, now: time.Tick) {
	if !w.started {
		w.started, w.next, w.newest = true, f.frame, f.frame
	}
	if serial_newer(w.next, f.frame) {
		return // older than what's been handed out
	}
	if f.frame - w.next >= VIDEO_WINDOW {
		// Too far ahead: what's before the window now won't be finished.
		start := f.frame - VIDEO_WINDOW + 1
		for fr := w.next; fr != start; fr += 1 {
			s := &w.slots[fr % VIDEO_WINDOW]
			if s.used && s.frame == fr {
				clear_slot(s)
			}
			w.given_up += 1
		}
		w.next, w.broken = start, true
	}
	if serial_newer(f.frame, w.newest) {
		w.newest = f.frame
	}
	// Every frame up to this one has a slot, so a skipped number is
	// missed (video_window_nacks).
	for fr := w.next; fr != f.frame; fr += 1 {
		slot_of(w, fr)
	}
	s := slot_of(w, f.frame)
	if s.gave_up {
		return
	}
	if s.count == 0 {
		s.count, s.key, s.ts, s.codec = f.count, f.key, f.ts, f.codec
	} else if f.count != s.count || f.key != s.key {
		return // doesn't belong with the others
	}
	if s.have[f.index] {
		return
	}
	s.have[f.index] = true
	s.received += 1
	s.newest = max(s.newest, f.index)
	s.last_at = now
	start := f.index * VIDEO_FRAGMENT_SIZE
	if len(s.buf) < s.count * VIDEO_FRAGMENT_SIZE {
		resize(&s.buf, s.count * VIDEO_FRAGMENT_SIZE)
	}
	copy(s.buf[start:], f.data)
	if f.index == f.count - 1 {
		s.size = start + len(f.data)
	}
	if complete(s) && s.rounds > 0 {
		w.recovered += 1
	}
}

/*
video_window_pop hands out the next frame that can be decoded, if
there is one: complete, in order, and while broken only a keyframe.
Its data is valid until the next video_window_add.
*/
@(require_results)
video_window_pop :: proc(w: ^Video_Window) -> (frame: Video_Frame, ok: bool) {
	if !w.started {
		return
	}
	if w.broken {
		// Straight to the first complete keyframe, if one is here:
		// nothing before it can be decoded anyway.
		for fr := w.next; fr != w.newest + 1; fr += 1 {
			s := &w.slots[fr % VIDEO_WINDOW]
			if s.used && s.frame == fr && s.key && complete(s) {
				for skip := w.next; skip != fr; skip += 1 {
					clear_slot(&w.slots[skip % VIDEO_WINDOW])
				}
				w.next = fr
				break
			}
		}
	}
	for w.next != w.newest + 1 {
		s := &w.slots[w.next % VIDEO_WINDOW]
		if !s.used || s.frame != w.next {
			return
		}
		switch {
		case complete(s):
			w.next += 1
			if w.broken && !s.key {
				clear_slot(s)
				continue
			}
			w.broken = false
			// The slot is free from here on, but its buffer stays as it
			// is until the slot is taken again.
			s.used = false
			return {
					frame = s.frame,
					ts = s.ts,
					key = s.key,
					codec = s.codec,
					data = s.buf[:s.size],
				},
				true
		case s.gave_up:
			w.next += 1
			w.broken = true
			clear_slot(s)
		case:
			return
		}
	}
	return
}

/*
video_window_nacks is what to ask for again at `now`, in the temp
allocator; it also gives up on frames that asking didn't bring. With
`asking` false nothing is asked for, and what would have been is given
up on at once.
*/
video_window_nacks :: proc(w: ^Video_Window, now: time.Tick, asking: bool) -> []Video_Nack {
	out := make([dynamic]Video_Nack, context.temp_allocator)
	if !w.started {
		return out[:]
	}
	for fr := w.next; fr != w.newest + 1; fr += 1 {
		s := &w.slots[fr % VIDEO_WINDOW]
		if !s.used || s.frame != fr || s.gave_up || complete(s) {
			continue
		}
		// How far it can be told to be missing.
		limit: int
		switch {
		case s.count == 0:
			limit = NACK_SPAN // of all we know, the start of it
		case fr != w.newest || time.tick_diff(s.last_at, now) >= TAIL_WAIT:
			limit = s.count
		case:
			limit = s.newest + 1
		}
		first := -1
		for i in 0 ..< limit {
			if !s.have[i] {
				first = i
				break
			}
		}
		if first < 0 {
			continue
		}
		if s.gap_at == {} {
			s.gap_at = now
		}
		switch s.rounds {
		case 0:
			if time.tick_diff(s.gap_at, now) < REORDER_WAIT {
				continue
			}
			if !asking {
				s.gave_up = true
				w.given_up += 1
				continue
			}
		case 1:
			if time.tick_diff(s.nack_at, now) < NACK_RETRY {
				continue
			}
		case:
			if time.tick_diff(s.nack_at, now) >= NACK_RETRY {
				s.gave_up = true
				w.given_up += 1
			}
			continue
		}
		s.rounds += 1
		s.nack_at = now
		if !asking {
			continue
		}
		sent := 0
		for start := first; start < limit && sent < MAX_NACKS_A_ROUND; start += NACK_SPAN {
			n := Video_Nack {
				frame = fr,
				first = start,
			}
			for i in start ..< min(start + NACK_SPAN, limit) {
				if !s.have[i] {
					n.missing |= u64(1) << uint(i - start)
					w.nacked += 1
				}
			}
			if n.missing != 0 {
				append(&out, n)
				sent += 1
			}
		}
	}
	return out[:]
}
