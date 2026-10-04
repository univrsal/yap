#+build !wasi
package proto

import "core:testing"

@(test)
test_purge_roundtrip :: proc(t: ^testing.T) {
	buf: [PURGE_SIZE]u8
	p := Purge{conv = 7, before = 1_790_000_000_000, what = .Images}
	got, ok := decode_purge(encode_purge(&buf, p))
	testing.expect(t, ok)
	testing.expect_value(t, got, p)
	// No time, an unknown what, too short: refused.
	_, ok = decode_purge(encode_purge(&buf, {conv = 7}))
	testing.expect(t, !ok)
	body := encode_purge(&buf, p)
	body[12] = 3
	_, ok = decode_purge(body)
	testing.expect(t, !ok)
	_, ok = decode_purge(body[:12])
	testing.expect(t, !ok)

	answer_buf: [PURGE_ANSWER_SIZE]u8
	messages, blobs, answer_ok := decode_purge_answer(encode_purge_answer(&answer_buf, 1234, 5))
	testing.expect(t, answer_ok)
	testing.expect_value(t, messages, 1234)
	testing.expect_value(t, blobs, 5)

	purged_buf: [MSGS_PURGED_SIZE]u8
	mp := Msgs_Purged{conv = 3, before = 99, what = .Messages}
	got_mp, mp_ok := decode_msgs_purged(encode_msgs_purged(&purged_buf, mp))
	testing.expect(t, mp_ok)
	testing.expect_value(t, got_mp, mp)
}
