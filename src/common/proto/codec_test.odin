#+build !wasi
package proto

import "core:testing"

@(test)
test_single_id_bodies :: proc(t: ^testing.T) {
	b8: [8]u8
	b4: [4]u8
	got_msg, ok := decode_msg_id(encode_msg_id(&b8, 77))
	testing.expect(t, ok && got_msg == 77)
	conv: Conv_Id
	conv, ok = decode_conv_id(encode_conv_id(&b4, 12))
	testing.expect(t, ok && conv == 12)

	// A body may go on past the id (a newer peer's), but not end before it.
	longer := [6]u8{5, 0, 0, 0, 9, 9}
	conv, ok = decode_conv_id(longer[:])
	testing.expect(t, ok && conv == 5)
	_, ok = decode_conv_id(longer[:3])
	testing.expect(t, !ok)
	_, ok = decode_msg_id(longer[:])
	testing.expect(t, !ok)

	// Room 0 is no room, and account 0 is the one asking; message and blob ids
	// are never 0.
	room: Room
	room, ok = decode_room(encode_room(&b4, 0))
	testing.expect(t, ok && room == 0)
	_, ok = decode_msg_id(encode_msg_id(&b8, 0))
	testing.expect(t, !ok)
	_, ok = decode_blob_id(encode_blob_id(&b8, 0))
	testing.expect(t, !ok)
}

@(test)
test_codec_helpers :: proc(t: ^testing.T) {
	buf: [4]u8
	w := Writer {
		buf = buf[:],
	}
	put_u16(&w, 1)
	testing.expect_value(t, len(written(&w)), 2)
	put_u32(&w, 2) // doesn't fit
	testing.expect(t, written(&w) == nil)

	body := [3]u8{2, 'h', 'i'}
	r := Reader {
		buf = body[:],
	}
	testing.expect(t, has_more(&r))
	testing.expect_value(t, get_str8_opt(&r), "hi")
	testing.expect(t, !has_more(&r))
	testing.expect_value(t, get_str8_opt(&r), "")
}
