#+build !wasi
package proto

import "core:testing"
import "core:time"

// A file goes from a sender to a receiver through a link that loses
// every fifth chunk and every third ack, and arrives whole.
@(test)
test_transfer_lossy :: proc(t: ^testing.T) {
	size := u64(2500 * FILE_CHUNK_DATA + 123) // more than two windows
	file := make([]u8, size)
	defer delete(file)
	for &b, i in file {
		b = u8(i * 7 + i / 1000)
	}
	got := make([]u8, size)
	defer delete(got)

	now := time.Tick {
		_nsec = 1_000_000_000,
	}
	s: Transfer_Sender
	transfer_sender_init(&s, size, now)
	defer transfer_sender_destroy(&s)
	r: Transfer_Receiver
	transfer_receiver_init(&r, size)
	defer transfer_receiver_destroy(&r)

	wire: [MAX_PAYLOAD_SIZE]u8
	sent, acks, rounds := 0, 0, 0
	done := false
	for ; rounds < 2000 && !done; rounds += 1 {
		now._nsec += i64(150 * time.Millisecond)
		transfer_refill(&s, now, 64 * 1024 * 1024, 4 * 1024 * 1024)
		for {
			index, first, ok := transfer_pick(&s, now)
			if !ok {
				break
			}
			start, end := file_chunk_range(size, index)
			msg := encode_transfer_chunk(wire[:], .Upload_Chunk, 9, index, file[start:end])
			transfer_sent(&s, index, first, int(end - start), now)
			sent += 1
			if sent % 5 == 0 {
				continue // lost
			}
			kind, kind_ok := message_kind(msg)
			testing.expect(t, kind_ok && kind == .Upload_Chunk)
			id, at, data := decode_transfer_chunk(msg)
			testing.expect_value(t, id, 9)
			if transfer_wants(&r, at, len(data)) {
				from, _ := file_chunk_range(size, at)
				copy(got[from:], data)
				transfer_got(&r, at, len(data))
			}
		}
		ack_msg := transfer_encode_ack(&r, wire[:], .Upload_Ack, 9, 0, now)
		acks += 1
		if acks % 3 == 0 && !transfer_complete(&r) {
			continue // lost
		}
		ack, count, missing, ok := decode_transfer_ack(ack_msg)
		testing.expect(t, ok)
		done = transfer_acked(&s, ack, count, missing, now)
	}
	testing.expect(t, done)
	testing.expect(t, transfer_complete(&r))
	testing.expect_value(t, transfer_sender_done(&s), size)
	testing.expect(t, string(got) == string(file))
	// Lost chunks were sent again, but not everything twice over.
	testing.expect(t, sent < int(s.chunks) * 2)
}

@(test)
test_transfer_messages :: proc(t: ^testing.T) {
	buf: [TRANSFER_CANCEL_SIZE]u8
	msg := encode_transfer_cancel(&buf, 1 << 40, .Cancelled)
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .Transfer_Cancel)
	id, reason := decode_transfer_cancel(msg)
	testing.expect_value(t, id, 1 << 40)
	testing.expect_value(t, reason, File_Cancel_Reason.Cancelled)

	// A chunk the receiver can't use: past the end, too short, a repeat.
	r: Transfer_Receiver
	transfer_receiver_init(&r, u64(FILE_CHUNK_DATA + 10))
	defer transfer_receiver_destroy(&r)
	testing.expect(t, !transfer_wants(&r, 2, 10))
	testing.expect(t, !transfer_wants(&r, 0, 10))
	testing.expect(t, transfer_wants(&r, 1, 10))
	transfer_got(&r, 1, 10)
	testing.expect(t, !transfer_wants(&r, 1, 10))
	testing.expect(t, !transfer_complete(&r))

	short := [3]u8{}
	_, _, _, ack_ok := decode_transfer_ack(short[:])
	testing.expect(t, !ack_ok)
}
