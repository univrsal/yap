package proto

import "core:encoding/endian"
import "core:time"

/*
Moving a file of any size in chunks, one way, between two ends that may
lose packets: a DM's file between two clients (files.odin), and an
attachment between a client and the server (attachments.odin).

The sender cuts the file into chunks of FILE_CHUNK_DATA bytes, chunk i
starting at byte i * FILE_CHUNK_DATA, and sends each once, at most
FILE_WINDOW ahead of what the receiver has, paced to a rate. The
receiver writes each where it goes as it comes, and every
TRANSFER_ACK_INTERVAL says what it has: everything below `base`, the
`highest` chunk that came, and which between those haven't (as many as
fit), which the sender sends again. If the acks stop moving once
everything has gone once, what's after `highest` may have been lost
too, and the sender sends that again on its own. Once everything's
there the ack says complete, a few times over.

	chunk   [kind][id u64][index u32][data]
	ack     [kind][id u64][max rate u32][base u32][highest u32][flags u8][count u16][missing u32...]
	cancel  [kind][id u64][reason u8]

`id` is the transfer's: a DM file's is its offer's message id, an
attachment's one the server handed out. A DM file's messages have
layouts of their own around these (File_Accept, File_Cancel carry the
other party), but its chunk and ack are these.

Transfer_Sender and Transfer_Receiver keep the bookkeeping for each end;
reading, writing and sending are their owners'.
*/

// How often the receiver says what it has.
TRANSFER_ACK_INTERVAL :: 100 * time.Millisecond
// A chunk asked for again isn't resent sooner than this after it last
// went, as it may still be on its way.
TRANSFER_RESEND_GAP :: 300 * time.Millisecond
// How long the acks may stand still before the sender resends the end.
TRANSFER_TAIL_WAIT :: time.Second
// How many times the receiver says it's complete.
TRANSFER_COMPLETE_ACKS :: 4

TRANSFER_CANCEL_SIZE :: 1 + 8 + 1

Transfer_Ack :: struct {
	id:       u64,
	max_rate: u32, // bytes per second the receiver takes; 0 for no limit
	base:     u32,
	highest:  u32,
	complete: bool,
}

encode_transfer_chunk :: proc(
	out: []u8,
	kind: Message_Kind,
	id: u64,
	index: u32,
	data: []u8,
) -> []u8 {
	out[0] = u8(kind)
	endian.unchecked_put_u64le(out[1:], id)
	endian.unchecked_put_u32le(out[9:], index)
	n := copy(out[FILE_CHUNK_HEADER_SIZE:], data)
	return out[:FILE_CHUNK_HEADER_SIZE + n]
}

// decode_transfer_chunk: the caller has checked it's at least a header
// long (message_kind).
decode_transfer_chunk :: proc(pt: []u8) -> (id: u64, index: u32, data: []u8) {
	return endian.unchecked_get_u64le(pt[1:]),
		endian.unchecked_get_u32le(pt[9:]),
		pt[FILE_CHUNK_HEADER_SIZE:]
}

// encode_transfer_ack writes as many of `missing` as fit.
encode_transfer_ack :: proc(
	out: []u8,
	kind: Message_Kind,
	ack: Transfer_Ack,
	missing: []u32,
) -> []u8 {
	count := min(len(missing), FILE_ACK_MAX_MISSING, (len(out) - FILE_ACK_HEADER_SIZE) / 4)
	out[0] = u8(kind)
	endian.unchecked_put_u64le(out[1:], ack.id)
	endian.unchecked_put_u32le(out[9:], ack.max_rate)
	endian.unchecked_put_u32le(out[13:], ack.base)
	endian.unchecked_put_u32le(out[17:], ack.highest)
	out[21] = FILE_ACK_COMPLETE if ack.complete else 0
	endian.unchecked_put_u16le(out[22:], u16(count))
	for i in 0 ..< count {
		endian.unchecked_put_u32le(out[FILE_ACK_HEADER_SIZE + i * 4:], missing[i])
	}
	return out[:FILE_ACK_HEADER_SIZE + count * 4]
}

// decode_transfer_ack returns the missing indices as the raw bytes they
// are in the packet; read them with file_ack_missing.
@(require_results)
decode_transfer_ack :: proc(pt: []u8) -> (ack: Transfer_Ack, count: int, missing: []u8, ok: bool) {
	if len(pt) < FILE_ACK_HEADER_SIZE {
		return
	}
	ack.id = endian.unchecked_get_u64le(pt[1:])
	ack.max_rate = endian.unchecked_get_u32le(pt[9:])
	ack.base = endian.unchecked_get_u32le(pt[13:])
	ack.highest = endian.unchecked_get_u32le(pt[17:])
	ack.complete = pt[21] & FILE_ACK_COMPLETE != 0
	count = int(endian.unchecked_get_u16le(pt[22:]))
	if len(pt) != FILE_ACK_HEADER_SIZE + count * 4 {
		return
	}
	return ack, count, pt[FILE_ACK_HEADER_SIZE:], true
}

encode_transfer_cancel :: proc(
	out: ^[TRANSFER_CANCEL_SIZE]u8,
	id: u64,
	reason: File_Cancel_Reason,
) -> []u8 {
	out[0] = u8(Message_Kind.Transfer_Cancel)
	endian.unchecked_put_u64le(out[1:], id)
	out[9] = u8(reason)
	return out[:]
}

decode_transfer_cancel :: proc(pt: []u8) -> (id: u64, reason: File_Cancel_Reason) {
	return endian.unchecked_get_u64le(pt[1:]), File_Cancel_Reason(pt[9])
}

/*
The sending end. Each turn: transfer_refill for what the pace allows,
then while transfer_pick has a chunk, read it, send it, and say so with
transfer_sent; what comes back goes to transfer_acked.
*/
Transfer_Sender :: struct {
	size:        u64,
	chunks:      u32,
	next:        u32, // the first chunk never sent
	base:        u32, // everything below has arrived
	highest:     u32,
	acked:       bool, // an ack has come, so `highest` means something
	progress_at: time.Tick, // when the acks last moved on
	resend:      [dynamic]u32,
	resent:      map[u32]time.Tick, // when a chunk last went
	tokens:      f32, // bytes that may go now
	last_pace:   time.Tick,
	peer_rate:   u32, // the receiver's limit, 0 for none
}

transfer_sender_init :: proc(s: ^Transfer_Sender, size: u64, now: time.Tick) {
	s^ = {
		size        = size,
		chunks      = file_chunk_count(size),
		progress_at = now,
		last_pace   = now,
	}
}

transfer_sender_destroy :: proc(s: ^Transfer_Sender) {
	delete(s.resend)
	delete(s.resent)
	s.resend, s.resent = nil, nil
}

// transfer_sender_done is how many bytes the receiver has for certain.
transfer_sender_done :: proc(s: ^Transfer_Sender) -> u64 {
	return min(u64(s.base) * FILE_CHUNK_DATA, s.size)
}

// transfer_refill adds what `rate` allows since the last turn, keeping
// at most `burst` (but always room for a chunk).
transfer_refill :: proc(s: ^Transfer_Sender, now: time.Tick, rate, burst: f32) {
	elapsed := f32(time.duration_seconds(time.tick_diff(s.last_pace, now)))
	s.last_pace = now
	s.tokens = min(s.tokens + elapsed * rate, max(burst, FILE_CHUNK_DATA))
}

// transfer_pick is the chunk to send next, if the pace and the window
// allow one: one asked for again first, then a new one.
transfer_pick :: proc(s: ^Transfer_Sender, now: time.Tick) -> (index: u32, first: bool, ok: bool) {
	if s.tokens <= 0 {
		return
	}
	// Everything sent once, but the acks have stopped moving: what's
	// after the highest chunk they have may have been lost too, and they
	// can't know to ask for it.
	if s.next == s.chunks &&
	   s.base < s.chunks &&
	   time.tick_diff(s.progress_at, now) > TRANSFER_TAIL_WAIT {
		from := s.base
		if s.acked {
			from = max(from, s.highest + 1)
		}
		for i := from; i < s.chunks && len(s.resend) < 64; i += 1 {
			queue_resend(s, i, now)
		}
		s.progress_at = now
	}
	for len(s.resend) > 0 {
		if s.resend[0] >= s.base {
			return s.resend[0], false, true
		}
		ordered_remove(&s.resend, 0)
	}
	if s.next < s.chunks && s.next < s.base + FILE_WINDOW {
		return s.next, true, true
	}
	return
}

// transfer_sent: chunk `index`, as transfer_pick gave it, has gone.
transfer_sent :: proc(s: ^Transfer_Sender, index: u32, first: bool, bytes: int, now: time.Tick) {
	if first {
		s.next += 1
	} else if len(s.resend) > 0 && s.resend[0] == index {
		ordered_remove(&s.resend, 0)
	}
	s.resent[index] = now
	s.tokens -= f32(bytes)
}

// transfer_acked takes what the receiver says it has; true once it has
// everything.
transfer_acked :: proc(
	s: ^Transfer_Sender,
	ack: Transfer_Ack,
	count: int,
	missing: []u8,
	now: time.Tick,
) -> bool {
	s.peer_rate = ack.max_rate
	if ack.complete {
		s.base = s.chunks
		return true
	}
	if ack.base > s.base || ack.highest > s.highest || !s.acked {
		s.progress_at = now
	}
	s.acked = true
	if ack.base > s.base && ack.base <= s.chunks {
		s.base = ack.base
		// A receiver that had some of it already (a download picked up
		// again): what it has needn't go at all.
		s.next = max(s.next, s.base)
		// What's below the base is theirs; no need to remember sending it.
		for index in s.resent {
			if index < s.base {
				delete_key(&s.resent, index)
			}
		}
	}
	if s.chunks > 0 {
		s.highest = max(s.highest, min(ack.highest, s.chunks - 1))
	}
	for i in 0 ..< count {
		queue_resend(s, file_ack_missing(missing, i), now)
	}
	return false
}

// queue_resend asks for chunk `index` to go again, unless it went lately
// or is already waiting to.
@(private = "file")
queue_resend :: proc(s: ^Transfer_Sender, index: u32, now: time.Tick) {
	if index >= s.next {
		return // not sent yet in the first place
	}
	if last, ok := s.resent[index]; ok && time.tick_diff(last, now) < TRANSFER_RESEND_GAP {
		return
	}
	for queued in s.resend {
		if queued == index {
			return
		}
	}
	append(&s.resend, index)
}

/*
The receiving end. A chunk that transfer_wants is written where
transfer_chunk_range says, then noted with transfer_got; every
TRANSFER_ACK_INTERVAL, and when it's complete, transfer_encode_ack says
so.
*/
Transfer_Receiver :: struct {
	size:          u64,
	chunks:        u32,
	have:          []u64, // a bit per chunk
	received:      u32,
	done:          u64, // bytes here
	base:          u32, // the first chunk not here
	highest:       u32,
	last_ack:      time.Tick,
	complete_acks: int,
}

transfer_receiver_init :: proc(r: ^Transfer_Receiver, size: u64) {
	chunks := file_chunk_count(size)
	r^ = {
		size   = size,
		chunks = chunks,
		have   = make([]u64, (chunks + 63) / 64),
	}
}

transfer_receiver_destroy :: proc(r: ^Transfer_Receiver) {
	delete(r.have)
	r.have = nil
}

// transfer_wants is whether chunk `index` with `n` bytes is one to keep:
// it belongs to the file, is as long as it should be, and isn't here yet.
transfer_wants :: proc(r: ^Transfer_Receiver, index: u32, n: int) -> bool {
	if index >= r.chunks || r.have[index / 64] & (1 << (index % 64)) != 0 {
		return false
	}
	start, end := file_chunk_range(r.size, index)
	return u64(n) == end - start
}

// transfer_got notes that chunk `index` (of `n` bytes) has been kept.
transfer_got :: proc(r: ^Transfer_Receiver, index: u32, n: int) {
	r.have[index / 64] |= 1 << (index % 64)
	r.received += 1
	r.done += u64(n)
	r.highest = max(r.highest, index)
	for r.base < r.chunks && r.have[r.base / 64] & (1 << (r.base % 64)) != 0 {
		r.base += 1
	}
}

transfer_complete :: proc(r: ^Transfer_Receiver) -> bool {
	return r.received == r.chunks
}

// transfer_encode_ack says what's here, and what's missing up to the
// highest chunk that came.
transfer_encode_ack :: proc(
	r: ^Transfer_Receiver,
	out: []u8,
	kind: Message_Kind,
	id: u64,
	max_rate: u32,
	now: time.Tick,
) -> []u8 {
	r.last_ack = now
	complete := transfer_complete(r)
	if complete {
		r.complete_acks += 1
	}
	missing: [FILE_ACK_MAX_MISSING]u32
	n := 0
	for i := r.base; i < r.highest && n < len(missing); i += 1 {
		if r.have[i / 64] & (1 << (i % 64)) == 0 {
			missing[n] = i
			n += 1
		}
	}
	ack := Transfer_Ack {
		id       = id,
		max_rate = max_rate,
		base     = r.base,
		highest  = r.highest,
		complete = complete,
	}
	return encode_transfer_ack(out, kind, ack, missing[:n])
}
