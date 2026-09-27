package proto

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/endian"

/*
Direct messages: text from one user to another, end-to-end encrypted,
relayed by the server, which holds on to them for a recipient who isn't
online and hands them over when they are.

	client -> server  DM_Send       [kind][id u64][to key 32][nonce 24][sealed...]
	server -> client  DM_Sent       [kind][id u64][result u8]
	server -> client  DM            [kind][id u64][from key 32][time u64][flags u8][nonce 24][sealed...]
	client -> server  DM_Ack        [kind][id u64][from key 32]
	server -> client  DM_Delivered  [kind][id u64][to key 32]
	client -> server  DM_Typing     [kind][to key 32]
	server -> client  DM_Typing     [kind][from key 32]

Users are addressed by public key rather than number, as a recipient
who's away has none.

Sending: the sender picks a random id and resends DM_Send until DM_Sent
answers it: Held means the server has it, Full that the recipient has
too many waiting already (MAX_HELD_DMS, MAX_HELD_DMS_FROM one sender)
and it was refused. The server remembers recent ids, so a resend isn't
held twice; the recipient drops any it already has as well.

Delivering: the server sends each held DM to the recipient, again every
CONTROL_RESEND, until DM_Ack says they have it; then it forgets it and,
if the sender is online, tells them with DM_Delivered (once, so the
sender may never hear). `time` is when the server took it in, and the
Waited flag says it came before the recipient's current connection did:
it was waiting for them rather than news (the client plays a different
sound for those).

Typing is unreliable and unencrypted, like the channel's, and only
reaches a recipient who's online.

Sealing: the key is HKDF-SHA256 over the X25519 of the sender's private
key and the recipient's public key - which the recipient gets from their
private key and the sender's public key, so only the two of them can
seal or open. That's also what makes the sender's key trustworthy: a DM
that opens was sealed by the key it names. The cipher is
XChaCha20-Poly1305 with a random nonce, over the text, with both keys and
the id as associated data, so the server can't move a DM to another
conversation or give it another id. There's no forward secrecy: a leaked
private key opens every DM it ever sent or received.
*/

DM_NONCE_SIZE :: 24
DM_KEY_SIZE :: 32
MAX_DM_SIZE :: MAX_CHAT_SIZE // bytes of UTF-8 text

// How many DMs the server holds for one recipient, in all and from one
// sender, so nobody can crowd out everyone else's.
MAX_HELD_DMS :: 50
MAX_HELD_DMS_FROM :: 20

DM_SEND_HEADER_SIZE :: 1 + 8 + KEY_SIZE + DM_NONCE_SIZE
DM_HEADER_SIZE :: 1 + 8 + KEY_SIZE + 8 + 1 + DM_NONCE_SIZE
DM_SENT_SIZE :: 1 + 8 + 1
DM_ACK_SIZE :: 1 + 8 + KEY_SIZE
DM_DELIVERED_SIZE :: 1 + 8 + KEY_SIZE
DM_TYPING_SIZE :: 1 + KEY_SIZE
MAX_DM_SEALED :: MAX_DM_SIZE + TAG_SIZE
MAX_DM_SIZE_ON_WIRE :: DM_HEADER_SIZE + MAX_DM_SEALED

DM_Flag :: enum u8 {
	Waited, // held while the recipient was away
}
DM_Flags :: distinct bit_set[DM_Flag;u8]

DM_Result :: enum u8 {
	Held = 1, // the server has it, and will deliver it
	Full = 2, // refused: too many are waiting for the recipient
}

@(private = "file")
DM_LABEL :: "yap dm v1"

/*
dm_key derives the key two users share for their DMs from one side's
private key and the other's public key. It returns false for a public
key that isn't one.
*/
dm_key :: proc(
	mine: ^ecdh.Private_Key,
	theirs: [KEY_SIZE]u8,
) -> (
	key: [DM_KEY_SIZE]u8,
	ok: bool,
) {
	theirs := theirs
	pub: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&pub, .X25519, theirs[:]) {
		return
	}
	shared: [32]u8
	defer crypto.zero_explicit(&shared, size_of(shared))
	if !ecdh.ecdh(mine, &pub, shared[:]) {
		return
	}
	label := DM_LABEL
	hkdf.extract_and_expand(.SHA256, transmute([]u8)label, shared[:], nil, key[:])
	return key, true
}

@(private = "file")
dm_aad :: proc(out: ^[2 * KEY_SIZE + 8]u8, from, to: [KEY_SIZE]u8, id: u64) -> []u8 {
	from, to := from, to
	copy(out[:], from[:])
	copy(out[KEY_SIZE:], to[:])
	endian.unchecked_put_u64le(out[2 * KEY_SIZE:], id)
	return out[:]
}

// dm_seal encrypts `text` (at most MAX_DM_SIZE bytes) into `out`, which
// must have room for it plus TAG_SIZE, and picks the nonce.
dm_seal :: proc(
	key: ^[DM_KEY_SIZE]u8,
	from, to: [KEY_SIZE]u8,
	id: u64,
	text: string,
	out: []u8,
) -> (
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) {
	crypto.rand_bytes(nonce[:])
	aad_buf: [2 * KEY_SIZE + 8]u8
	n := len(text)
	aead.seal_oneshot(
		.XCHACHA20POLY1305,
		out[:n],
		out[n:][:TAG_SIZE],
		key[:],
		nonce[:],
		dm_aad(&aad_buf, from, to, id),
		transmute([]u8)text,
	)
	return nonce, out[:n + TAG_SIZE]
}

// dm_open decrypts a sealed DM into `out`, which needs len(sealed) -
// TAG_SIZE bytes. The text isn't sanitized yet.
dm_open :: proc(
	key: ^[DM_KEY_SIZE]u8,
	from, to: [KEY_SIZE]u8,
	id: u64,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
	out: []u8,
) -> (
	text: string,
	ok: bool,
) {
	nonce := nonce
	if len(sealed) < TAG_SIZE || len(sealed) - TAG_SIZE > len(out) {
		return
	}
	n := len(sealed) - TAG_SIZE
	aad_buf: [2 * KEY_SIZE + 8]u8
	if !aead.open_oneshot(
		.XCHACHA20POLY1305,
		out[:n],
		key[:],
		nonce[:],
		dm_aad(&aad_buf, from, to, id),
		sealed[:n],
		sealed[n:],
	) {
		return
	}
	return string(out[:n]), true
}

encode_dm_send :: proc(
	out: []u8,
	id: u64,
	to: [KEY_SIZE]u8,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) -> []u8 {
	to, nonce := to, nonce
	out[0] = u8(Message_Kind.DM_Send)
	endian.unchecked_put_u64le(out[1:], id)
	copy(out[9:], to[:])
	copy(out[9 + KEY_SIZE:], nonce[:])
	copy(out[DM_SEND_HEADER_SIZE:], sealed)
	return out[:DM_SEND_HEADER_SIZE + len(sealed)]
}

// decode_dm_send reads a DM_Send; message_kind has checked the size.
decode_dm_send :: proc(
	pt: []u8,
) -> (
	id: u64,
	to: [KEY_SIZE]u8,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) {
	id = endian.unchecked_get_u64le(pt[1:])
	copy(to[:], pt[9:])
	copy(nonce[:], pt[9 + KEY_SIZE:])
	sealed = pt[DM_SEND_HEADER_SIZE:]
	return
}

encode_dm_sent :: proc(out: ^[DM_SENT_SIZE]u8, id: u64, result: DM_Result) -> []u8 {
	out[0] = u8(Message_Kind.DM_Sent)
	endian.unchecked_put_u64le(out[1:], id)
	out[9] = u8(result)
	return out[:]
}

// decode_dm_sent may return a result this build has no name for.
decode_dm_sent :: proc(pt: []u8) -> (id: u64, result: DM_Result) {
	return endian.unchecked_get_u64le(pt[1:]), DM_Result(pt[9])
}

encode_dm :: proc(
	out: []u8,
	id: u64,
	from: [KEY_SIZE]u8,
	time: Unix_Time,
	flags: DM_Flags,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) -> []u8 {
	from, nonce := from, nonce
	out[0] = u8(Message_Kind.DM)
	endian.unchecked_put_u64le(out[1:], id)
	copy(out[9:], from[:])
	endian.unchecked_put_u64le(out[9 + KEY_SIZE:], u64(time))
	out[17 + KEY_SIZE] = transmute(u8)flags
	copy(out[18 + KEY_SIZE:], nonce[:])
	copy(out[DM_HEADER_SIZE:], sealed)
	return out[:DM_HEADER_SIZE + len(sealed)]
}

// decode_dm reads a DM; message_kind has checked the size.
decode_dm :: proc(
	pt: []u8,
) -> (
	id: u64,
	from: [KEY_SIZE]u8,
	time: Unix_Time,
	flags: DM_Flags,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) {
	id = endian.unchecked_get_u64le(pt[1:])
	copy(from[:], pt[9:])
	time = Unix_Time(endian.unchecked_get_u64le(pt[9 + KEY_SIZE:]))
	flags = transmute(DM_Flags)pt[17 + KEY_SIZE]
	copy(nonce[:], pt[18 + KEY_SIZE:])
	sealed = pt[DM_HEADER_SIZE:]
	return
}

// encode_dm_key_message writes the messages that are an id and a key:
// DM_Ack (the sender's key) and DM_Delivered (the recipient's).
encode_dm_key_message :: proc(
	out: ^[DM_ACK_SIZE]u8,
	kind: Message_Kind,
	id: u64,
	key: [KEY_SIZE]u8,
) -> []u8 {
	key := key
	out[0] = u8(kind)
	endian.unchecked_put_u64le(out[1:], id)
	copy(out[9:], key[:])
	return out[:]
}

decode_dm_key_message :: proc(pt: []u8) -> (id: u64, key: [KEY_SIZE]u8) {
	id = endian.unchecked_get_u64le(pt[1:])
	copy(key[:], pt[9:])
	return
}

// encode_dm_typing writes a DM_Typing either way: the recipient's key
// going up, the sender's coming down.
encode_dm_typing :: proc(out: ^[DM_TYPING_SIZE]u8, key: [KEY_SIZE]u8) -> []u8 {
	key := key
	out[0] = u8(Message_Kind.DM_Typing)
	copy(out[1:], key[:])
	return out[:]
}

decode_dm_typing :: proc(pt: []u8) -> (key: [KEY_SIZE]u8) {
	copy(key[:], pt[1:])
	return
}
