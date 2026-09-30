#+build !wasi
package proto

import "core:strings"
import "core:testing"

@(test)
test_poke_roundtrip :: proc(t: ^testing.T) {
	buf: [POKE_MAX_SIZE]u8
	for text in ([]string{"", "hey, you there?", "Zoë ☺"}) {
		msg := encode_poke(&buf, 3, 7, text)
		kind, ok := message_kind(msg)
		testing.expect(t, ok)
		testing.expect_value(t, kind, Message_Kind.Poke)
		sender, target, got := decode_poke(msg)
		testing.expect_value(t, sender, 3)
		testing.expect_value(t, target, 7)
		testing.expect_value(t, got, text)
	}
}

@(test)
test_poke_limits :: proc(t: ^testing.T) {
	buf: [POKE_MAX_SIZE]u8
	// Longer than the length byte can say: cut to what fits.
	long := strings.repeat("x", MAX_POKE_SIZE + 20, context.temp_allocator)
	msg := encode_poke(&buf, 1, 2, long)
	testing.expect_value(t, len(msg), POKE_MAX_SIZE)
	_, _, got := decode_poke(msg)
	testing.expect_value(t, len(got), MAX_POKE_SIZE)

	// A length that disagrees with the packet is refused.
	short := encode_poke(&buf, 1, 2, "hello")
	_, ok := message_kind(short[:len(short) - 1])
	testing.expect(t, !ok)
	_, ok = message_kind(short[:POKE_HEADER_SIZE - 1])
	testing.expect(t, !ok)
}
