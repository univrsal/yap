#+build !wasi
package proto

import "core:strings"
import "core:testing"

@(test)
test_chat_roundtrip :: proc(t: ^testing.T) {
	long := strings.repeat("x", MAX_CHAT_SIZE, context.temp_allocator)
	entries := []Chat_Entry {
		{id = 5, sender = 1, time = 1_700_000_000, name = "alice", text = "hi"},
		{id = 6, sender = 2, time = 1_700_000_001, name = "", text = "Zoë says ☺"},
		{id = 7, sender = 1, time = 1_700_000_002, name = "alice", text = long},
		{id = 8, sender = 1, time = 1_700_000_003, name = "alice", text = long},
		{id = 9, sender = 1, time = 1_700_000_004, name = "alice", text = long},
	}
	out: [MAX_PAYLOAD_SIZE]u8
	msg, count := encode_chat(out[:], 3, 4, entries)
	// Two long messages fit, the third goes in the next packet.
	testing.expect_value(t, count, 4)
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .Chat)

	buf: [128]Chat_Entry
	channel, base, got, ok := decode_chat(msg, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, channel, 3)
	testing.expect_value(t, base, 4)
	testing.expect_value(t, len(got), count)
	for e, i in got {
		testing.expect_value(t, e, entries[i])
	}

	// Truncated or padded packets are rejected.
	_, _, _, ok = decode_chat(msg[:len(msg) - 1], buf[:])
	testing.expect(t, !ok)
	padded := out[:len(msg) + 1]
	_, _, _, ok = decode_chat(padded, buf[:])
	testing.expect(t, !ok)
}

@(test)
test_chat_small_messages :: proc(t: ^testing.T) {
	send_buf: [CHAT_SEND_HEADER_SIZE + MAX_CHAT_SIZE]u8
	msg := encode_chat_send(send_buf[:], 0xdead_beef_0123, "hello")
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .Chat_Send)
	nonce, text := decode_chat_send(msg)
	testing.expect_value(t, nonce, 0xdead_beef_0123)
	testing.expect_value(t, text, "hello")
	// The length field has to match.
	_, ok = message_kind(msg[:len(msg) - 1])
	testing.expect(t, !ok)

	sent_buf: [CHAT_SENT_SIZE]u8
	testing.expect_value(t, decode_chat_sent(encode_chat_sent(&sent_buf, 42)), 42)

	recv_buf: [CHAT_RECEIVED_SIZE]u8
	channel, id := decode_chat_received(encode_chat_received(&recv_buf, 2, 99))
	testing.expect_value(t, channel, 2)
	testing.expect_value(t, id, 99)

	typing_buf: [TYPING_DOWN_SIZE]u8
	typing := encode_typing_down(&typing_buf, 17)
	kind, ok = message_kind(typing)
	testing.expect(t, ok && kind == .Typing)
	testing.expect_value(t, decode_typing_down(typing), 17)
}

@(test)
test_sanitize_text :: proc(t: ^testing.T) {
	buf: [MAX_CHAT_SIZE]u8
	testing.expect_value(t, sanitize_text("  a\tb\r\nc\x00‮  ", buf[:]), "a b  c")
	long := strings.repeat("é", MAX_CHAT_SIZE, context.temp_allocator)
	got := sanitize_text(long, buf[:])
	// Cut at a character boundary.
	testing.expect_value(t, len(got), MAX_CHAT_SIZE)
}

@(test)
test_chat_image_entries :: proc(t: ^testing.T) {
	entries := []Chat_Entry {
		{id = 1, sender = 3, time = 1_700_000_000, name = "alice", kind = .Text, text = "look"},
		{
			id = 2,
			sender = 3,
			time = 1_700_000_001,
			name = "alice",
			kind = .Image,
			image = {id = 77, width = 1920, height = 1080, size = 200_000},
		},
		// An image the server no longer has.
		{id = 3, sender = 4, name = "bob", kind = .Image, image = {id = 0, width = 64, height = 64, size = 900}},
	}
	out: [MAX_PAYLOAD_SIZE]u8
	msg, count := encode_chat(out[:], 1, 0, entries)
	testing.expect_value(t, count, 3)

	buf: [8]Chat_Entry
	_, _, got, ok := decode_chat(msg, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 3)
	for e, i in got {
		testing.expect_value(t, e, entries[i])
	}

	// An entry kind we don't know is refused rather than guessed at.
	bad := make([]u8, len(msg), context.temp_allocator)
	copy(bad, msg)
	bad[CHAT_HEADER_SIZE + 4 + 4 + 4 + 1 + len("alice")] = 9
	_, _, _, ok = decode_chat(bad, buf[:])
	testing.expect(t, !ok)
}
