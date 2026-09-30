#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:testing"

@(test)
test_file_offer_and_chunks :: proc(t: ^testing.T) {
	alice, bob: ecdh.Private_Key
	alice_pub, bob_pub: [KEY_SIZE]u8
	testing.expect(t, ecdh.private_key_generate(&alice, .X25519))
	testing.expect(t, ecdh.private_key_generate(&bob, .X25519))
	defer ecdh.private_key_clear(&alice)
	defer ecdh.private_key_clear(&bob)
	ecdh.private_key_public_bytes(&alice, alice_pub[:])
	ecdh.private_key_public_bytes(&bob, bob_pub[:])
	k_ab, _ := dm_key(&alice, bob_pub)
	k_ba, _ := dm_key(&bob, alice_pub)

	offer := DM_File {
		size = 3 * FILE_CHUNK_DATA + 10,
		name = "holiday.mp4",
	}
	offer.prefix[0] = 42
	body_buf: [MAX_DM_BODY]u8
	content, _, _, got, ok := decode_dm_body(encode_dm_file(&body_buf, offer))
	testing.expect(t, ok)
	testing.expect_value(t, content, DM_Content.File)
	testing.expect_value(t, got.size, offer.size)
	testing.expect_value(t, got.name, "holiday.mp4")
	testing.expect(t, got.prefix == offer.prefix)
	testing.expect_value(t, file_chunk_count(offer.size), 4)
	start, end := file_chunk_range(offer.size, 3)
	testing.expect_value(t, end - start, 10)

	// A chunk opens only as the index it was sealed as.
	data := [5]u8{1, 2, 3, 4, 5}
	sealed_buf: [FILE_CHUNK_DATA + TAG_SIZE]u8
	sealed := dm_seal_with(
		&k_ab,
		alice_pub,
		bob_pub,
		7,
		.File,
		file_chunk_nonce(offer.prefix, 2),
		data[:],
		sealed_buf[:],
	)
	wire: [MAX_PAYLOAD_SIZE]u8
	msg := encode_file_chunk(wire[:], 7, 2, sealed)
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .File_Chunk)
	id, index, got_sealed := decode_file_chunk(msg)
	out: [FILE_CHUNK_DATA]u8
	opened, open_ok := dm_open(
		&k_ba,
		alice_pub,
		bob_pub,
		id,
		.File,
		file_chunk_nonce(offer.prefix, index),
		got_sealed,
		out[:],
	)
	testing.expect(t, open_ok)
	testing.expect(t, string(opened) == string(data[:]))
	_, open_ok = dm_open(
		&k_ba,
		alice_pub,
		bob_pub,
		id,
		.File,
		file_chunk_nonce(offer.prefix, 3),
		got_sealed,
		out[:],
	)
	testing.expect(t, !open_ok, "a chunk opened as another index")
	_, open_ok = dm_open(
		&k_ba,
		alice_pub,
		bob_pub,
		id,
		.Body,
		file_chunk_nonce(offer.prefix, 2),
		got_sealed,
		out[:],
	)
	testing.expect(t, !open_ok, "a chunk opened as a message")
}

@(test)
test_file_messages :: proc(t: ^testing.T) {
	key: [KEY_SIZE]u8
	key[0] = 5
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
	accept := encode_file_accept(&accept_buf, 9, key, 500)
	other: [KEY_SIZE]u8
	other[0] = 6
	set_file_message_key(accept, other)
	id, got_key, rate := decode_file_accept(accept)
	testing.expect_value(t, id, 9)
	testing.expect(t, got_key == other)
	testing.expect_value(t, rate, 500)

	cancel_buf: [FILE_CANCEL_SIZE]u8
	_, _, reason := decode_file_cancel(encode_file_cancel(&cancel_buf, 9, key, .Declined))
	testing.expect_value(t, reason, File_Cancel_Reason.Declined)
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

@(test)
test_last_seen_messages :: proc(t: ^testing.T) {
	keys: [3][KEY_SIZE]u8
	for &k, i in keys {
		k[0] = u8(i + 1)
	}
	buf: [MAX_PAYLOAD_SIZE]u8
	get := encode_last_seen_get(buf[:], keys[:])
	kind, ok := message_kind(get)
	testing.expect(t, ok && kind == .Last_Seen_Get)
	testing.expect_value(t, last_seen_count(get), 3)
	testing.expect(t, last_seen_get_key(get, 2) == keys[2])

	times := [3]Unix_Time{0, 1000, 2000}
	out: [MAX_PAYLOAD_SIZE]u8
	answer := encode_last_seen(out[:], keys[:], times[:])
	kind, ok = message_kind(answer)
	testing.expect(t, ok && kind == .Last_Seen)
	key, seen := last_seen_entry(answer, 1)
	testing.expect(t, key == keys[1])
	testing.expect_value(t, seen, Unix_Time(1000))
}
