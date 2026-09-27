#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:testing"

@(private = "file")
new_key :: proc(t: ^testing.T) -> (priv: ecdh.Private_Key, pub: [KEY_SIZE]u8) {
	testing.expect(t, ecdh.private_key_generate(&priv, .X25519))
	ecdh.private_key_public_bytes(&priv, pub[:])
	return
}

@(test)
test_dm_round_trip :: proc(t: ^testing.T) {
	alice, alice_pub := new_key(t)
	bob, bob_pub := new_key(t)
	eve, eve_pub := new_key(t)
	defer ecdh.private_key_clear(&alice)
	defer ecdh.private_key_clear(&bob)
	defer ecdh.private_key_clear(&eve)

	// Both ends come to the same key; anyone else doesn't.
	k_ab, ok1 := dm_key(&alice, bob_pub)
	k_ba, ok2 := dm_key(&bob, alice_pub)
	k_eb, ok3 := dm_key(&eve, bob_pub)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect(t, k_ab == k_ba)
	testing.expect(t, k_eb != k_ab)

	sealed_buf: [MAX_DM_SEALED]u8
	nonce, sealed := dm_seal(&k_ab, alice_pub, bob_pub, 42, "hello bob", sealed_buf[:])

	// Through the wire format and back.
	wire_buf: [MAX_DM_SIZE_ON_WIRE]u8
	msg := encode_dm(wire_buf[:], 42, alice_pub, 1234, {.Waited}, nonce, sealed)
	kind, kind_ok := message_kind(msg)
	testing.expect(t, kind_ok && kind == .DM)
	id, from, when_, flags, got_nonce, got_sealed := decode_dm(msg)
	testing.expect_value(t, id, 42)
	testing.expect(t, from == alice_pub)
	testing.expect_value(t, when_, Unix_Time(1234))
	testing.expect_value(t, flags, DM_Flags{.Waited})

	out: [MAX_DM_SIZE]u8
	text, ok := dm_open(&k_ba, from, bob_pub, id, got_nonce, got_sealed, out[:])
	testing.expect(t, ok)
	testing.expect_value(t, text, "hello bob")

	// Eve can't read it, and the server can't pass it off as from
	// someone else or under another id.
	_, ok = dm_open(&k_eb, alice_pub, bob_pub, 42, nonce, sealed, out[:])
	testing.expect(t, !ok, "someone else opened it")
	_, ok = dm_open(&k_ba, eve_pub, bob_pub, 42, nonce, sealed, out[:])
	testing.expect(t, !ok, "opened under another sender")
	_, ok = dm_open(&k_ba, alice_pub, bob_pub, 43, nonce, sealed, out[:])
	testing.expect(t, !ok, "opened under another id")
	sealed[0] ~= 1
	_, ok = dm_open(&k_ba, alice_pub, bob_pub, 42, nonce, sealed, out[:])
	testing.expect(t, !ok, "opened after tampering")
}

@(test)
test_dm_messages :: proc(t: ^testing.T) {
	key: [KEY_SIZE]u8
	key[3] = 9
	sent_buf: [DM_SENT_SIZE]u8
	id, result := decode_dm_sent(encode_dm_sent(&sent_buf, 7, .Full))
	testing.expect_value(t, id, 7)
	testing.expect_value(t, result, DM_Result.Full)

	ack_buf: [DM_ACK_SIZE]u8
	ack := encode_dm_key_message(&ack_buf, .DM_Ack, 8, key)
	kind, ok := message_kind(ack)
	testing.expect(t, ok && kind == .DM_Ack)
	got_id, got_key := decode_dm_key_message(ack)
	testing.expect_value(t, got_id, 8)
	testing.expect(t, got_key == key)

	typing_buf: [DM_TYPING_SIZE]u8
	testing.expect(t, decode_dm_typing(encode_dm_typing(&typing_buf, key)) == key)

	// Nothing longer than a DM may be sent as one.
	big: [DM_SEND_HEADER_SIZE + MAX_DM_SEALED + 1]u8
	big[0] = u8(Message_Kind.DM_Send)
	_, ok = message_kind(big[:])
	testing.expect(t, !ok)
}
