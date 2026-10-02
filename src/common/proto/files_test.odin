#+build !wasi
package proto

import "core:testing"

@(test)
test_file_chunks :: proc(t: ^testing.T) {
	size := u64(3 * FILE_CHUNK_DATA + 10)
	testing.expect_value(t, file_chunk_count(size), 4)
	start, end := file_chunk_range(size, 3)
	testing.expect_value(t, end - start, 10)

	data := [5]u8{1, 2, 3, 4, 5}
	wire: [MAX_PAYLOAD_SIZE]u8
	msg := encode_file_chunk(wire[:], 7, 2, data[:])
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .File_Chunk)
	id, index, got := decode_file_chunk(msg)
	testing.expect_value(t, id, Msg_Id(7))
	testing.expect_value(t, index, 2)
	testing.expect(t, string(got) == string(data[:]))

	// A whole chunk fits in a datagram.
	full: [FILE_CHUNK_DATA]u8
	msg = encode_file_chunk(wire[:], 7, 0, full[:])
	testing.expect_value(t, len(msg), MAX_PAYLOAD_SIZE)
	_, kind_ok = message_kind(msg)
	testing.expect(t, kind_ok)
}

@(test)
test_file_messages :: proc(t: ^testing.T) {
	ack_buf: [MAX_PAYLOAD_SIZE]u8
	missing := [3]u32{10, 12, 99}
	msg := encode_file_ack(
		ack_buf[:],
		{id = 1, max_rate = 1000, base = 10, highest = 120, complete = false},
		missing[:],
	)
	kind, ok := message_kind(msg)
	testing.expect(t, ok && kind == .File_Ack)
	ack, count, raw, ack_ok := decode_file_ack(msg)
	testing.expect(t, ack_ok)
	testing.expect_value(t, ack.base, 10)
	testing.expect_value(t, ack.highest, 120)
	testing.expect_value(t, ack.max_rate, 1000)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, file_ack_missing(raw, 2), 99)

	accept_buf: [FILE_ACCEPT_SIZE]u8
	accept := encode_file_accept(&accept_buf, 9, 5, 500)
	kind, ok = message_kind(accept)
	testing.expect(t, ok && kind == .File_Accept)
	set_file_message_account(accept, 6)
	id, account, rate := decode_file_accept(accept)
	testing.expect_value(t, id, Msg_Id(9))
	testing.expect_value(t, account, Account_Id(6))
	testing.expect_value(t, rate, 500)

	cancel_buf: [FILE_CANCEL_SIZE]u8
	cancel := encode_file_cancel(&cancel_buf, 9, 5, .Elsewhere)
	kind, ok = message_kind(cancel)
	testing.expect(t, ok && kind == .File_Cancel)
	reason: File_Cancel_Reason
	_, account, reason = decode_file_cancel(cancel)
	testing.expect_value(t, account, Account_Id(5))
	testing.expect_value(t, reason, File_Cancel_Reason.Elsewhere)
}

@(test)
test_file_names :: proc(t: ^testing.T) {
	buf: [MAX_FILE_NAME]u8
	testing.expect_value(t, sanitize_file_name("../../etc/passwd.zip", &buf), "passwd.zip")
	testing.expect_value(t, sanitize_file_name("C:\\Users\\me\\a<b>:c.png", &buf), "abc.png")
	testing.expect_value(t, sanitize_file_name("..hidden.mkv", &buf), "hidden.mkv")
	testing.expect_value(t, sanitize_file_name("  ", &buf), "")

	testing.expect(t, file_type_allowed("clip.MP4"))
	testing.expect(t, file_type_allowed("backup.tar.gz"))
	testing.expect(t, !file_type_allowed("setup.exe"))
	testing.expect(t, !file_type_allowed("script.sh"))
	testing.expect(t, !file_type_allowed("noext"))
	testing.expect(t, !file_type_allowed("trailingdot."))
}
