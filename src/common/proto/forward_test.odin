#+build !wasi
package proto

import "core:testing"

@(test)
test_links :: proc(t: ^testing.T) {
	text := "see <msg:12:3456> and <msg:1:2>"
	l, ok := next_link(text, 0)
	testing.expect(t, ok)
	testing.expect_value(t, l, Msg_Link{start = 4, end = 17, conv = 12, id = 3456})
	l, ok = next_link(text, l.end)
	testing.expect(t, ok)
	testing.expect_value(t, l.conv, Conv_Id(1))
	testing.expect_value(t, l.id, Msg_Id(2))
	_, ok = next_link(text, l.end)
	testing.expect(t, !ok)
	// What only looks like one is text.
	for bad in ([]string {
			"<msg:>",
			"<msg:12>",
			"<msg:0:5>",
			"<msg:a:5>",
			"<msg:12:5",
			"<msg:1:0>",
		}) {
		_, ok = next_link(bad, 0)
		testing.expectf(t, !ok, "%q is a link", bad)
	}
	// Past a broken one to a whole one.
	l, ok = next_link("<msg:x <msg:3:4>", 0)
	testing.expect(t, ok && l.conv == 3 && l.id == 4)
	testing.expect_value(t, link_token(12, 3456), "<msg:12:3456>")
}

@(test)
test_forwarded_message :: proc(t: ^testing.T) {
	m := Message {
		id = 9,
		conv = 2,
		sender = 3,
		kind = .Text,
		flags = {.Forwarded},
		text = "words",
		forward = {sender = 5, conv = 6, time = 777},
	}
	buf: [MESSAGE_MAX_SIZE]u8
	body := encode_message(buf[:], m)
	testing.expect_value(t, len(body), message_size(m))
	got, ok := decode_message(body)
	testing.expect(t, ok)
	testing.expect_value(t, got.forward, m.forward)
	testing.expect_value(t, got.text, "words")

	fwd_buf: [MSG_FORWARD_SIZE]u8
	f, f_ok := decode_msg_forward(
		encode_msg_forward(&fwd_buf, {conv = 2, nonce = 7, thread_root = 3, msg = 4}),
	)
	testing.expect(t, f_ok)
	testing.expect_value(t, f, Msg_Forward{conv = 2, nonce = 7, thread_root = 3, msg = 4})
	_, f_ok = decode_msg_forward(encode_msg_forward(&fwd_buf, {conv = 2, msg = 4}))
	testing.expect(t, !f_ok, "no nonce")
}
