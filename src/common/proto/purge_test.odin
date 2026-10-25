#+build !wasi
package proto

import "core:testing"

@(test)
test_purge_roundtrip :: proc(t: ^testing.T) {
	buf: [PURGE_MAX_SIZE]u8
	p := Purge {
		conv   = 7,
		before = 1_790_000_000_000,
		what   = .Files,
	}
	got, ok := decode_purge(encode_purge(&buf, p))
	testing.expect(t, ok)
	testing.expect_value(t, got, p)
	testing.expect_value(t, len(encode_purge(&buf, p)), PURGE_SIZE)

	// One author's messages: no time, but an author and from when on.
	by_author := Purge {
		conv   = 0,
		author = 4,
		since  = 1_790_000_000_000,
	}
	got, ok = decode_purge(encode_purge(&buf, by_author))
	testing.expect(t, ok)
	testing.expect_value(t, got, by_author)
	// Both a time and an author is refused.
	by_author.before = 1
	_, ok = decode_purge(encode_purge(&buf, by_author))
	testing.expect(t, !ok)
	// A purge without a time, with an unknown `what` value, or truncated is
	// refused.
	_, ok = decode_purge(encode_purge(&buf, {conv = 7}))
	testing.expect(t, !ok)
	body := encode_purge(&buf, p)
	body[12] = 2
	_, ok = decode_purge(body)
	testing.expect(t, !ok)
	_, ok = decode_purge(body[:12])
	testing.expect(t, !ok)

	answer_buf: [PURGE_ANSWER_SIZE]u8
	messages, blobs, answer_ok := decode_purge_answer(encode_purge_answer(&answer_buf, 1234, 5))
	testing.expect(t, answer_ok)
	testing.expect_value(t, messages, 1234)
	testing.expect_value(t, blobs, 5)

	purged_buf: [MSGS_PURGED_MAX_SIZE]u8
	mp := Msgs_Purged {
		conv   = 3,
		before = 99,
		what   = .Messages,
	}
	got_mp, mp_ok := decode_msgs_purged(encode_msgs_purged(&purged_buf, mp))
	testing.expect(t, mp_ok)
	testing.expect_value(t, got_mp, mp)
	testing.expect_value(t, len(encode_msgs_purged(&purged_buf, mp)), MSGS_PURGED_SIZE)

	mp = {
		conv   = 3,
		author = 4,
		from   = 50,
	}
	got_mp, mp_ok = decode_msgs_purged(encode_msgs_purged(&purged_buf, mp))
	testing.expect(t, mp_ok)
	testing.expect_value(t, got_mp, mp)
	// A truncated author is refused.
	_, mp_ok = decode_msgs_purged(encode_msgs_purged(&purged_buf, mp)[:MSGS_PURGED_SIZE + 2])
	testing.expect(t, !mp_ok)
}
