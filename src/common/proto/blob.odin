package proto

import "core:encoding/endian"

// Blob transfer: moves a few hundred kilobytes (such as a profile picture) in
// both directions through the same encrypted Data packets as everything else.
//
// 	sender -> receiver  Blob_Chunk [kind][handle u64][index u16][data]
// 	receiver -> sender  Blob_Need  [kind][handle u64][flags u8][count u16][index u16]...
//
// The receiver always knows the size in advance, and therefore how many chunks
// to expect. An upload is announced with Blob_Put, and a download is requested
// with Blob_Get, whose answer contains the size (see msgs.odin). A `handle`
// identifies the transfer, and the server hands one out for each transfer.
//
// The sender pushes chunks at its own pace. The receiver requests the chunks
// that haven't arrived with Blob_Need and repeats the request until all gaps
// are filled. When everything has arrived it sends Blob_Need with the complete
// flag, which also tells the sender that it can drop the transfer. If the
// server receives an upload that turns out not to be what was announced, it
// answers with the failed flag instead. Blob_Need is unreliable like
// everything else, so both sides repeat their messages until the other side's
// answer shows that they got through.

BLOB_CHUNK_HEADER_SIZE :: 1 + 8 + 2
BLOB_CHUNK_SIZE :: MAX_PAYLOAD_SIZE - BLOB_CHUNK_HEADER_SIZE
BLOB_NEED_HEADER_SIZE :: 1 + 8 + 1 + 2
BLOB_NEED_MAX_INDICES :: (MAX_PAYLOAD_SIZE - BLOB_NEED_HEADER_SIZE) / 2
// The largest blob that is ever transferred. It is large enough for a server's
// sheet of custom emoji at its maximum size (emoji.odin).
MAX_BLOB_SIZE :: 1024 * 1024
MAX_BLOB_CHUNKS :: (MAX_BLOB_SIZE + BLOB_CHUNK_SIZE - 1) / BLOB_CHUNK_SIZE

// Blob_Need flags.
BLOB_COMPLETE :: 1 << 0
BLOB_FAILED :: 1 << 1

blob_chunk_count :: proc(size: int) -> int {
	return (size + BLOB_CHUNK_SIZE - 1) / BLOB_CHUNK_SIZE
}

// blob_chunk_range returns the part of a blob that chunk `index` carries.
blob_chunk_range :: proc(size, index: int) -> (start, end: int) {
	start = index * BLOB_CHUNK_SIZE
	return start, min(start + BLOB_CHUNK_SIZE, size)
}

encode_blob_chunk :: proc(out: []u8, handle: u64, index: int, data: []u8) -> []u8 {
	out[0] = u8(Message_Kind.Blob_Chunk)
	endian.unchecked_put_u64le(out[1:], handle)
	endian.unchecked_put_u16le(out[9:], u16(index))
	n := copy(out[BLOB_CHUNK_HEADER_SIZE:], data)
	return out[:BLOB_CHUNK_HEADER_SIZE + n]
}

decode_blob_chunk :: proc(pt: []u8) -> (handle: u64, index: int, data: []u8) {
	return endian.unchecked_get_u64le(pt[1:]),
		int(endian.unchecked_get_u16le(pt[9:])),
		pt[BLOB_CHUNK_HEADER_SIZE:]
}

// encode_blob_need writes as many of `indices` as fit and returns the message
// together with the number of indices that it contains.
encode_blob_need :: proc(
	out: []u8,
	handle: u64,
	complete: bool,
	indices: []u16,
	failed := false,
) -> (
	msg: []u8,
	count: int,
) {
	count = min(len(indices), (len(out) - BLOB_NEED_HEADER_SIZE) / 2, BLOB_NEED_MAX_INDICES)
	out[0] = u8(Message_Kind.Blob_Need)
	endian.unchecked_put_u64le(out[1:], handle)
	out[9] = (BLOB_COMPLETE if complete else 0) | (BLOB_FAILED if failed else 0)
	endian.unchecked_put_u16le(out[10:], u16(count))
	for i in 0 ..< count {
		endian.unchecked_put_u16le(out[BLOB_NEED_HEADER_SIZE + i * 2:], indices[i])
	}
	return out[:BLOB_NEED_HEADER_SIZE + count * 2], count
}

// decode_blob_need returns the indices as the raw bytes of the packet. Use
// blob_need_index to read them.
@(require_results)
decode_blob_need :: proc(
	pt: []u8,
) -> (
	handle: u64,
	complete: bool,
	count: int,
	indices: []u8,
	ok: bool,
) {
	if len(pt) < BLOB_NEED_HEADER_SIZE {
		return
	}
	handle = endian.unchecked_get_u64le(pt[1:])
	complete = pt[9] & BLOB_COMPLETE != 0
	count = int(endian.unchecked_get_u16le(pt[10:]))
	if count > BLOB_NEED_MAX_INDICES || len(pt) != BLOB_NEED_HEADER_SIZE + count * 2 {
		return
	}
	return handle, complete, count, pt[BLOB_NEED_HEADER_SIZE:], true
}

// blob_need_failed reports whether a Blob_Need (that decodes successfully)
// says that the upload was refused.
blob_need_failed :: proc(pt: []u8) -> bool {
	return len(pt) >= BLOB_NEED_HEADER_SIZE && pt[9] & BLOB_FAILED != 0
}

blob_need_index :: proc(indices: []u8, i: int) -> int {
	return int(endian.unchecked_get_u16le(indices[i * 2:]))
}

// Blob_Receiver collects the chunks of one transfer.
Blob_Receiver :: struct {
	size:     int,
	data:     []u8, // owned
	have:     []bool, // per chunk
	received: int, // chunks stored
	scan:     int, // where the next search for gaps starts
}

blob_receiver_init :: proc(r: ^Blob_Receiver, size: int, allocator := context.allocator) -> bool {
	if size <= 0 || size > MAX_BLOB_SIZE {
		return false
	}
	r^ = {
		size = size,
		data = make([]u8, size, allocator),
		have = make([]bool, blob_chunk_count(size), allocator),
	}
	return true
}

blob_receiver_destroy :: proc(r: ^Blob_Receiver, allocator := context.allocator) {
	delete(r.data, allocator)
	delete(r.have, allocator)
	r^ = {}
}

// blob_receive stores one chunk and ignores duplicates and invalid chunks.
blob_receive :: proc(r: ^Blob_Receiver, index: int, data: []u8) {
	if index < 0 || index >= len(r.have) || r.have[index] {
		return
	}
	start, end := blob_chunk_range(r.size, index)
	if len(data) != end - start {
		return
	}
	copy(r.data[start:end], data)
	r.have[index] = true
	r.received += 1
}

blob_receiver_complete :: proc(r: ^Blob_Receiver) -> bool {
	return r.size > 0 && r.received == len(r.have)
}

// blob_missing fills `out` with the chunks that haven't arrived. It continues
// where the last call stopped, so repeated calls cover all missing chunks.
blob_missing :: proc(r: ^Blob_Receiver, out: []u16) -> []u16 {
	n := 0
	for i in 0 ..< len(r.have) {
		if n == len(out) {
			break
		}
		index := (r.scan + i) % len(r.have)
		if !r.have[index] {
			out[n] = u16(index)
			n += 1
		}
	}
	if n > 0 {
		r.scan = (int(out[n - 1]) + 1) % len(r.have)
	}
	return out[:n]
}

// Blob_Sender sends each chunk of a blob once and afterwards any chunks that
// are requested again.
Blob_Sender :: struct {
	data:   []u8, // borrowed
	next:   int, // next chunk of the first pass
	resend: [dynamic]int,
}

blob_sender_destroy :: proc(s: ^Blob_Sender) {
	delete(s.resend)
	s^ = {}
}

// blob_sender_needs queues a chunk that the receiver requested again.
blob_sender_needs :: proc(s: ^Blob_Sender, index: int) {
	if index < 0 || index >= blob_chunk_count(len(s.data)) {
		return
	}
	for queued in s.resend {
		if queued == index {
			return
		}
	}
	append(&s.resend, index)
}

// blob_next_chunk returns the next chunk to send. That is a chunk that was
// requested again, or otherwise the next one that was never sent.
blob_next_chunk :: proc(s: ^Blob_Sender) -> (index: int, data: []u8, ok: bool) {
	switch {
	case len(s.resend) > 0:
		index = s.resend[0]
		ordered_remove(&s.resend, 0)
	case s.next < blob_chunk_count(len(s.data)):
		index = s.next
		s.next += 1
	case:
		return 0, nil, false
	}
	start, end := blob_chunk_range(len(s.data), index)
	return index, s.data[start:end], true
}

// blob_sender_idle returns true when no chunk is waiting to be sent.
blob_sender_idle :: proc(s: ^Blob_Sender) -> bool {
	return len(s.resend) == 0 && s.next >= blob_chunk_count(len(s.data))
}
