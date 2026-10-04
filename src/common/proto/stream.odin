package proto

import "core:container/queue"
import "core:encoding/endian"
import "core:time"

/*
The reliable stream: whole application messages, delivered once and in
order, in each direction of a connection. It rides in Data packets like
everything else, which on their own are neither reliable nor ordered.

	either -> other  Stream      [kind][seq u32][flags u8][data]
	either -> other  Stream_Ack  [kind][next u32][mask u64]

A message is cut into frames, numbered from 0 for each direction of a
connection. STREAM_MORE in `flags` says the message goes on in the next
frame; a frame without it ends one. A message is at most
STREAM_MAX_MESSAGE, and one that comes out longer is an error the
connection doesn't survive.

Stream_Ack says what has arrived: every frame below `next`, and frame
next + 1 + i for each bit i set in `mask`. The sender has at most
STREAM_WINDOW frames out past the receiver's `next`, resends one that
goes unacknowledged for a while (longer each time), and resends at once
one the mask shows was passed over.

A Stream is only the bookkeeping. It has no socket and no clock: whoever
owns it passes the time in, sends the frames stream_next_frame hands out
(as fast as it sees fit: that's where pacing goes), and feeds in what
arrives. Its state belongs to the connection rather than a session, so
it carries across rekeys. What tells a rekey from a connection starting
over, where both ends start again from 0, is the Welcome (names.odin).
*/

STREAM_HEADER_SIZE :: 1 + 4 + 1
STREAM_FRAME_DATA :: MAX_PAYLOAD_SIZE - STREAM_HEADER_SIZE
STREAM_ACK_SIZE :: 1 + 4 + 8
STREAM_WINDOW :: 64
STREAM_MAX_MESSAGE :: 64 * 1024

// Stream flags.
STREAM_MORE :: 1 << 0

// How long a frame goes unacknowledged before it's sent again, unless
// the owner knows the round trip: doubled with each resend of the same
// frame, up to STREAM_RESEND_MAX.
STREAM_RESEND :: CONTROL_RESEND
STREAM_RESEND_MIN :: 100 * time.Millisecond
STREAM_RESEND_MAX :: 2 * time.Second

Stream_Error :: enum {
	None,
	Too_Large, // a message longer than STREAM_MAX_MESSAGE
}

// A frame that's been sent and not yet acknowledged from the start.
@(private = "file")
Stream_Out :: struct {
	data:    []u8, // owned; freed once acknowledged
	more:    bool,
	sent:    time.Tick,
	sends:   int,
	acked:   bool, // by the mask, ahead of the ones before it
	skipped: bool, // a later one arrived: resend now
	hurried: bool, // already resent for that once; after that it waits
}

// A frame that arrived ahead of one still missing.
@(private = "file")
Stream_In :: struct {
	data: []u8, // owned
	more: bool,
	have: bool,
}

Stream :: struct {
	// Sending: whole messages waiting their turn, and how much of the
	// first has gone out as frames already.
	waiting:   queue.Queue([]u8), // each owned
	queued:    int, // bytes of them not yet in a frame
	offset:    int,
	max_queue: int, // what `queued` may come to; 0 for no limit
	out:       [STREAM_WINDOW]Stream_Out, // by seq % STREAM_WINDOW
	send_base: u32, // everything below it is acknowledged
	send_next: u32, // the next new frame's number

	// Receiving.
	recv_next: u32, // everything below it arrived
	recv:      [STREAM_WINDOW]Stream_In, // by seq % STREAM_WINDOW
	partial:   [dynamic]u8, // the message whose end hasn't come yet
	ready:     queue.Queue([]u8), // whole messages not yet taken; each owned
	taken:     []u8, // the one stream_next handed out last; owned
	ack_due:   bool,
}

// stream_reset starts both directions over, as for a new connection.
// The queue's limit stays.
stream_reset :: proc(s: ^Stream) {
	for queue.len(s.waiting) > 0 {
		delete(queue.pop_front(&s.waiting))
	}
	for &f in s.out {
		delete(f.data)
		f = {}
	}
	for &f in s.recv {
		delete(f.data)
		f = {}
	}
	for queue.len(s.ready) > 0 {
		delete(queue.pop_front(&s.ready))
	}
	delete(s.taken)
	clear(&s.partial)
	s.taken = nil
	s.queued, s.offset = 0, 0
	s.send_base, s.send_next, s.recv_next = 0, 0, 0
	s.ack_due = false
}

stream_destroy :: proc(s: ^Stream) {
	stream_reset(s)
	queue.destroy(&s.waiting)
	queue.destroy(&s.ready)
	delete(s.partial)
	s^ = {}
}

// stream_send queues a message, which it copies. It returns false for
// one that can't go: empty, too long, or more than the queue may hold,
// which means the other end has fallen too far behind to catch up.
@(require_results)
stream_send :: proc(s: ^Stream, message: []u8) -> bool {
	if len(message) == 0 ||
	   len(message) > STREAM_MAX_MESSAGE ||
	   (s.max_queue > 0 && s.queued + len(message) > s.max_queue) {
		return false
	}
	m := make([]u8, len(message))
	copy(m, message)
	queue.push_back(&s.waiting, m)
	s.queued += len(m)
	return true
}

// stream_idle is whether there's nothing left to send or to hear back
// about.
stream_idle :: proc(s: ^Stream) -> bool {
	return s.send_base == s.send_next && queue.len(s.waiting) == 0
}

@(private = "file")
resend_after :: proc(resend: time.Duration, sends: int) -> time.Duration {
	return min(resend << uint(min(sends - 1, 5)), STREAM_RESEND_MAX)
}

/*
stream_next_frame writes the next Stream message that should go out now
into `out` (MAX_PAYLOAD_SIZE will hold any): a frame due for resending
before a new one. `resend` is how long a frame waits for its
acknowledgement the first time. Call it until it has nothing, or until
enough has been sent for now.
*/
@(require_results)
stream_next_frame :: proc(
	s: ^Stream,
	now: time.Tick,
	resend: time.Duration,
	out: []u8,
) -> (
	msg: []u8,
	ok: bool,
) {
	for seq := s.send_base; seq != s.send_next; seq += 1 {
		f := &s.out[seq % STREAM_WINDOW]
		if f.acked || (!f.skipped && time.tick_diff(f.sent, now) < resend_after(resend, f.sends)) {
			continue
		}
		f.skipped = false
		f.sent = now
		f.sends += 1
		return encode_stream(out, seq, f.more, f.data), true
	}

	if queue.len(s.waiting) == 0 || s.send_next - s.send_base >= STREAM_WINDOW {
		return
	}
	rest := queue.front(&s.waiting)[s.offset:]
	n := min(len(rest), STREAM_FRAME_DATA)
	seq := s.send_next
	f := &s.out[seq % STREAM_WINDOW]
	f^ = {
		data  = make([]u8, n),
		more  = n < len(rest),
		sent  = now,
		sends = 1,
	}
	copy(f.data, rest)
	s.send_next += 1
	s.offset += n
	s.queued -= n
	if !f.more {
		delete(queue.pop_front(&s.waiting))
		s.offset = 0
	}
	return encode_stream(out, seq, f.more, f.data), true
}

// stream_acked takes a Stream_Ack; message_kind has checked its size.
stream_acked :: proc(s: ^Stream, pt: []u8) {
	next, mask := decode_stream_ack(pt)
	out := s.send_next - s.send_base
	// One from before the last we heard, or for frames never sent.
	if next - s.send_base > out {
		return
	}
	for s.send_base != next {
		f := &s.out[s.send_base % STREAM_WINDOW]
		delete(f.data)
		f^ = {}
		s.send_base += 1
	}

	// Those that arrived ahead of `next`, and with them which ones were
	// passed over: everything unacknowledged below the highest of them.
	highest := -1
	for i in 0 ..< 64 {
		if mask & (u64(1) << uint(i)) == 0 {
			continue
		}
		seq := next + 1 + u32(i)
		if seq - s.send_base >= s.send_next - s.send_base {
			break
		}
		f := &s.out[seq % STREAM_WINDOW]
		if !f.acked {
			delete(f.data)
			f.data = nil
			f.acked = true
		}
		highest = i
	}
	for i in 0 ..= highest {
		f := &s.out[(next + u32(i)) % STREAM_WINDOW]
		if !f.acked && !f.hurried {
			f.skipped, f.hurried = true, true
		}
	}
}

/*
stream_receive takes a Stream message; message_kind has checked its
size. Whole messages it completes are then there for stream_next. An
error means the other end broke the rules, and the connection should go.
*/
@(require_results)
stream_receive :: proc(s: ^Stream, pt: []u8) -> Stream_Error {
	seq, more, data := decode_stream(pt)
	ahead := seq - s.recv_next
	if ahead >= STREAM_WINDOW {
		// One we have already, so our acknowledgement didn't get there;
		// or one from beyond the window, which a sender never sends.
		if i32(ahead) < 0 {
			s.ack_due = true
		}
		return .None
	}
	if slot := &s.recv[seq % STREAM_WINDOW]; !slot.have {
		slot^ = {
			data = make([]u8, len(data)),
			more = more,
			have = true,
		}
		copy(slot.data, data)
	}
	s.ack_due = true

	for {
		slot := &s.recv[s.recv_next % STREAM_WINDOW]
		if !slot.have {
			break
		}
		if len(s.partial) + len(slot.data) > STREAM_MAX_MESSAGE {
			return .Too_Large
		}
		append(&s.partial, ..slot.data)
		ends := !slot.more
		delete(slot.data)
		slot^ = {}
		s.recv_next += 1
		if ends {
			m := make([]u8, len(s.partial))
			copy(m, s.partial[:])
			queue.push_back(&s.ready, m)
			clear(&s.partial)
		}
	}
	return .None
}

// stream_next hands out the next whole message, in the order they were
// sent. It stays valid until the next call.
@(require_results)
stream_next :: proc(s: ^Stream) -> (message: []u8, ok: bool) {
	delete(s.taken)
	s.taken = nil
	if queue.len(s.ready) == 0 {
		return
	}
	s.taken = queue.pop_front(&s.ready)
	return s.taken, true
}

// stream_ack writes the Stream_Ack that's due, if one is: something
// arrived since the last.
@(require_results)
stream_ack :: proc(s: ^Stream, out: ^[STREAM_ACK_SIZE]u8) -> (msg: []u8, ok: bool) {
	if !s.ack_due {
		return
	}
	s.ack_due = false
	mask: u64
	for i in 0 ..< STREAM_WINDOW - 1 {
		if s.recv[(s.recv_next + 1 + u32(i)) % STREAM_WINDOW].have {
			mask |= u64(1) << uint(i)
		}
	}
	return encode_stream_ack(out, s.recv_next, mask), true
}

encode_stream :: proc(out: []u8, seq: u32, more: bool, data: []u8) -> []u8 {
	out[0] = u8(Message_Kind.Stream)
	endian.unchecked_put_u32le(out[1:], seq)
	out[5] = STREAM_MORE if more else 0
	n := copy(out[STREAM_HEADER_SIZE:], data)
	return out[:STREAM_HEADER_SIZE + n]
}

// decode_stream reads a Stream; `data` points into `pt`.
decode_stream :: proc(pt: []u8) -> (seq: u32, more: bool, data: []u8) {
	return endian.unchecked_get_u32le(pt[1:]), pt[5] & STREAM_MORE != 0, pt[STREAM_HEADER_SIZE:]
}

encode_stream_ack :: proc(out: ^[STREAM_ACK_SIZE]u8, next: u32, mask: u64) -> []u8 {
	out[0] = u8(Message_Kind.Stream_Ack)
	endian.unchecked_put_u32le(out[1:], next)
	endian.unchecked_put_u64le(out[5:], mask)
	return out[:]
}

decode_stream_ack :: proc(pt: []u8) -> (next: u32, mask: u64) {
	return endian.unchecked_get_u32le(pt[1:]), endian.unchecked_get_u64le(pt[5:])
}
