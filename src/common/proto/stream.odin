package proto

import "core:container/queue"
import "core:encoding/endian"
import "core:time"

// The reliable stream delivers whole application messages exactly once and
// in order, in each direction of a connection. It is carried in Data packets
// like everything else, which on their own are neither reliable nor ordered.
//
//	either -> other  Stream      [kind][seq u32][flags u8][data]
//	either -> other  Stream_Ack  [kind][next u32][mask u64]
//
// A message is cut into frames, which are numbered from 0 for each direction
// of a connection. STREAM_MORE in `flags` says that the message continues in
// the next frame, and a frame without it ends the message. A message is at
// most STREAM_MAX_MESSAGE long, and a longer one is an error that the
// connection doesn't survive.
//
// Stream_Ack says what has arrived: every frame below `next`, and frame
// next + 1 + i for each bit i that is set in `mask`. The sender has at most
// STREAM_WINDOW frames in flight past the receiver's `next`. It resends a
// frame that stays unacknowledged for a while (waiting longer each time) and
// resends a frame immediately if the mask shows that it was skipped.
//
// A Stream only does the bookkeeping. It has no socket and no clock: its
// owner passes in the time, sends the frames that stream_next_frame hands
// out (at whatever pace it sees fit, which is where pacing is done) and
// feeds in whatever arrives. Its state belongs to the connection rather than
// to a session, so it carries across rekeys. A rekey is told apart from a
// connection starting over, where both ends restart from 0, by the Welcome
// (hello.odin).

STREAM_HEADER_SIZE :: 1 + 4 + 1
STREAM_FRAME_DATA :: MAX_PAYLOAD_SIZE - STREAM_HEADER_SIZE
STREAM_ACK_SIZE :: 1 + 4 + 8
STREAM_WINDOW :: 64
STREAM_MAX_MESSAGE :: 64 * 1024

// Stream flags.
STREAM_MORE :: 1 << 0

// How long a frame stays unacknowledged before it is sent again, unless the
// owner knows the round trip time. The wait doubles with each resend of the
// same frame, up to STREAM_RESEND_MAX.
STREAM_RESEND :: CONTROL_RESEND
STREAM_RESEND_MIN :: 100 * time.Millisecond
STREAM_RESEND_MAX :: 2 * time.Second

Stream_Error :: enum {
	None,
	Too_Large, // a message is longer than STREAM_MAX_MESSAGE
}

// A frame that has been sent and isn't yet covered by the acknowledged base.
@(private = "file")
Stream_Out :: struct {
	data:    []u8, // owned; freed once acknowledged
	more:    bool,
	sent:    time.Tick,
	sends:   int,
	acked:   bool, // acknowledged by the mask, ahead of the frames before it
	skipped: bool, // a later frame arrived, so resend now
	hurried: bool, // already resent early once, after that it waits normally
}

// A frame that arrived ahead of a frame that is still missing.
@(private = "file")
Stream_In :: struct {
	data: []u8, // owned
	more: bool,
	have: bool,
}

Stream :: struct {
	// Sending: whole messages waiting to be sent, and how much of the first
	// one has already gone out as frames.
	waiting:   queue.Queue([]u8), // each owned
	queued:    int, // bytes of those not yet in a frame
	offset:    int,
	max_queue: int, // the maximum value of `queued`, 0 for no limit
	out:       [STREAM_WINDOW]Stream_Out, // by seq % STREAM_WINDOW
	send_base: u32, // everything below it is acknowledged
	send_next: u32, // the number of the next new frame

	// Receiving.
	recv_next: u32, // everything below it arrived
	recv:      [STREAM_WINDOW]Stream_In, // by seq % STREAM_WINDOW
	partial:   [dynamic]u8, // the message whose end hasn't arrived yet
	ready:     queue.Queue([]u8), // whole messages not yet taken; each owned
	taken:     []u8, // the message stream_next handed out last, owned
	ack_due:   bool,
}

// stream_reset starts both directions over, like for a new connection.
// The queue's limit is kept.
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

// stream_send queues a copy of a message. It returns false if the message
// can't be sent because it is empty, too long, or would exceed what the queue
// may hold, which means that the other end has fallen too far behind to catch
// up.
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

// stream_idle says whether there is nothing left to send and no
// acknowledgement left to wait for.
stream_idle :: proc(s: ^Stream) -> bool {
	return s.send_base == s.send_next && queue.len(s.waiting) == 0
}

@(private = "file")
resend_after :: proc(resend: time.Duration, sends: int) -> time.Duration {
	return min(resend << uint(min(sends - 1, 5)), STREAM_RESEND_MAX)
}

// stream_next_frame writes the next Stream message that should be sent now
// into `out` (MAX_PAYLOAD_SIZE is enough for any). A frame that is due for
// resending comes before a new one. `resend` is how long a frame waits for
// its acknowledgement the first time. Call it until it returns nothing, or
// until enough has been sent for now.
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
	// This is either older than the last ack we received, or for frames that
	// were never sent.
	if next - s.send_base > out {
		return
	}
	for s.send_base != next {
		f := &s.out[s.send_base % STREAM_WINDOW]
		delete(f.data)
		f^ = {}
		s.send_base += 1
	}

	// Frames that arrived ahead of `next`, and with them the frames that were
	// skipped, which is everything unacknowledged below the highest of them.
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

// stream_receive takes a Stream message (message_kind has checked its size).
// Whole messages that it completes can then be fetched with stream_next. An
// error means that the other end broke the rules and the connection should
// be closed.
@(require_results)
stream_receive :: proc(s: ^Stream, pt: []u8) -> Stream_Error {
	seq, more, data := decode_stream(pt)
	ahead := seq - s.recv_next
	if ahead >= STREAM_WINDOW {
		// Either a frame we already have, which means our acknowledgement
		// didn't arrive, or one from beyond the window, which a sender never
		// sends.
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
// sent. The message stays valid until the next call.
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

// stream_ack writes the Stream_Ack that is due, if there is one, which is
// the case when something arrived since the last ack.
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

// decode_stream reads a Stream. `data` points into `pt`.
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
