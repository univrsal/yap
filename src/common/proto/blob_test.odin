#+build !wasi
package proto

import "core:math/rand"
import "core:testing"

@(test)
test_blob_messages :: proc(t: ^testing.T) {
	data := make([]u8, 3 * BLOB_CHUNK_SIZE + 7, context.temp_allocator)
	for &b, i in data {
		b = u8(i)
	}
	testing.expect_value(t, blob_chunk_count(len(data)), 4)

	out: [MAX_PAYLOAD_SIZE]u8
	start, end := blob_chunk_range(len(data), 3)
	msg := encode_blob_chunk(out[:], 0x1234_5678_9abc, 3, data[start:end])
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .Blob_Chunk)
	handle, index, chunk := decode_blob_chunk(msg)
	testing.expect_value(t, handle, 0x1234_5678_9abc)
	testing.expect_value(t, index, 3)
	testing.expect_value(t, len(chunk), 7)

	indices := []u16{0, 5, 65535}
	need, count := encode_blob_need(out[:], 42, false, indices)
	testing.expect_value(t, count, 3)
	kind, kind_ok = message_kind(need)
	testing.expect(t, kind_ok && kind == .Blob_Need)
	got_handle, complete, got_count, got, ok := decode_blob_need(need)
	testing.expect(t, ok && !complete)
	testing.expect_value(t, got_handle, 42)
	testing.expect_value(t, got_count, 3)
	for want, i in indices {
		testing.expect_value(t, blob_need_index(got, i), int(want))
	}

	done, _ := encode_blob_need(out[:], 42, true, nil)
	_, complete, got_count, _, ok = decode_blob_need(done)
	testing.expect(t, ok && complete && got_count == 0)
	// Truncated packets are refused.
	_, _, _, _, ok = decode_blob_need(need[:len(need) - 1])
	testing.expect(t, !ok)
}

// A transfer where a third of the chunks go missing still completes:
// the receiver keeps asking for what it hasn't got.
@(test)
test_blob_transfer_with_loss :: proc(t: ^testing.T) {
	data := make([]u8, 200 * 1024, context.temp_allocator)
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	for &b in data {
		b = u8(rand.int_max(256))
	}

	sender := Blob_Sender {
		data = data,
	}
	defer blob_sender_destroy(&sender)
	receiver: Blob_Receiver
	testing.expect(t, blob_receiver_init(&receiver, len(data), context.temp_allocator))
	defer blob_receiver_destroy(&receiver, context.temp_allocator)

	packet: [MAX_PAYLOAD_SIZE]u8
	need_buf: [BLOB_NEED_MAX_INDICES]u16
	for round in 0 ..< 20 {
		// Send whatever is queued, losing a third of it.
		for {
			index, chunk, ok := blob_next_chunk(&sender)
			if !ok {
				break
			}
			if rand.int_max(3) == 0 {
				continue // lost
			}
			msg := encode_blob_chunk(packet[:], 1, index, chunk)
			handle, got_index, got := decode_blob_chunk(msg)
			testing.expect_value(t, handle, 1)
			blob_receive(&receiver, got_index, got)
		}
		if blob_receiver_complete(&receiver) {
			break
		}
		// Ask again for what's missing.
		missing := blob_missing(&receiver, need_buf[:])
		testing.expect(t, len(missing) > 0)
		need, _ := encode_blob_need(packet[:], 1, false, missing)
		_, _, count, indices, ok := decode_blob_need(need)
		testing.expect(t, ok)
		for i in 0 ..< count {
			blob_sender_needs(&sender, blob_need_index(indices, i))
		}
		testing.expectf(t, round < 19, "still incomplete after %d rounds", round + 1)
	}
	testing.expect(t, blob_receiver_complete(&receiver))
	for b, i in receiver.data {
		if b != data[i] {
			testing.expectf(t, false, "byte %d differs", i)
			break
		}
	}
}
