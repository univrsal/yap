package proto

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/endian"
import "core:time"

/*
Direct messages: text or images from one user to another, end-to-end
encrypted, relayed by the server, which holds on to text for a recipient
who isn't online and hands it over when they are. Images only go to
someone who's online.

	client -> server  DM_Send        [kind][id u64][to key 32][nonce 24][sealed body...]
	client -> server  DM_Image_Send  [kind][id u64][to key 32][nonce 24][image size u32][sealed body...]
	server -> client  DM_Sent        [kind][id u64][result u8]
	server -> client  DM             [kind][id u64][from key 32][time u64][flags u8][nonce 24][sealed body...]
	client -> server  DM_Ack         [kind][id u64][from key 32]
	server -> client  DM_Delivered   [kind][id u64][to key 32]
	client -> server  DM_Typing      [kind][to key 32]
	server -> client  DM_Typing      [kind][from key 32]
	client -> server  DM_Image_Get   [kind][id u64][from key 32]
	server -> client  DM_Image_Gone  [kind][id u64][from key 32]

The body, once opened, says what the DM is:

	text   [0][text...]
	image  [1][width u16][height u16][size u32][image nonce 24]
	file   [2]... an offer to send a file (see files.odin)

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

Images: the sender seals the JPEG on its own (the image nonce, with
Image as the part in the associated data) and announces the DM with
DM_Image_Send, which gives the server the sealed image's size. If the
recipient is online the server asks for the image with Blob_Need, the
handle being the DM's id, and the sender uploads it in Blob_Chunks (see
blob.odin); then the DM is held like any other and DM_Sent says Held.
Offline means the recipient isn't there, and nothing was kept. The
recipient opens the DM, asks for the image with DM_Image_Get and gets it
the same way, in chunks under the DM's id. The server keeps the sealed
image in memory only, until the recipient has it or DM_IMAGE_KEEP has
passed; after that DM_Image_Gone answers.

Sealing: the key is HKDF-SHA256 over the X25519 of the sender's private
key and the recipient's public key - which the recipient gets from their
private key and the sender's public key, so only the two of them can
seal or open. That's also what makes the sender's key trustworthy: a DM
that opens was sealed by the key it names. The cipher is
XChaCha20-Poly1305 with a random nonce, over the body, with both keys,
the id and which part it is (the body or an image's bytes) as associated
data, so the server can't move a DM to another conversation, give it
another id, or pass an image off as a message. There's no forward secrecy: a leaked
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
DM_IMAGE_SEND_HEADER_SIZE :: DM_SEND_HEADER_SIZE + 4
DM_IMAGE_REF_SIZE :: 1 + 8 + KEY_SIZE // DM_Image_Get, DM_Image_Gone
MAX_DM_BODY :: 1 + MAX_DM_SIZE
MAX_DM_SEALED :: MAX_DM_BODY + TAG_SIZE
MAX_DM_SIZE_ON_WIRE :: DM_IMAGE_SEND_HEADER_SIZE + MAX_DM_SEALED
DM_IMAGE_BODY_SIZE :: 1 + 2 + 2 + 4 + DM_NONCE_SIZE
// The most an image may be once sealed: a chat image's worth plus its
// tag, which MAX_BLOB_SIZE leaves room for.
MAX_DM_IMAGE_SEALED :: MAX_BLOB_SIZE
// How long the server keeps an image for a recipient who hasn't fetched it.
DM_IMAGE_KEEP :: 10 * time.Minute

// What a DM is.
DM_Content :: enum u8 {
	Text  = 0,
	Image = 1,
	File  = 2, // files.odin
}

// DM_Image is what an image DM's body says about the image.
DM_Image :: struct {
	width, height: u16,
	size:          u32, // sealed, as it's transferred
	nonce:         [DM_NONCE_SIZE]u8, // what it's sealed with
}

// Which part of a DM something sealed is.
DM_Part :: enum u8 {
	Body  = 0,
	Image = 1,
	File  = 2, // a file transfer's chunk (files.odin)
}

DM_Flag :: enum u8 {
	Waited, // held while the recipient was away
}
DM_Flags :: distinct bit_set[DM_Flag;u8]

DM_Result :: enum u8 {
	Held = 1, // the server has it, and will deliver it
	Full = 2, // refused: too many are waiting for the recipient
	Offline = 3, // refused: an image, and the recipient isn't online
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
DM_AAD_SIZE :: 2 * KEY_SIZE + 8 + 1

@(private = "file")
dm_aad :: proc(out: ^[DM_AAD_SIZE]u8, from, to: [KEY_SIZE]u8, id: u64, part: DM_Part) -> []u8 {
	from, to := from, to
	copy(out[:], from[:])
	copy(out[KEY_SIZE:], to[:])
	endian.unchecked_put_u64le(out[2 * KEY_SIZE:], id)
	out[2 * KEY_SIZE + 8] = u8(part)
	return out[:]
}

// dm_seal encrypts `data` into `out`, which must have room for it plus
// TAG_SIZE, and picks the nonce.
dm_seal :: proc(
	key: ^[DM_KEY_SIZE]u8,
	from, to: [KEY_SIZE]u8,
	id: u64,
	part: DM_Part,
	data: []u8,
	out: []u8,
) -> (
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
) {
	crypto.rand_bytes(nonce[:])
	return nonce, dm_seal_with(key, from, to, id, part, nonce, data, out)
}

// dm_seal_with is dm_seal with a nonce of the caller's: a file chunk's
// (see file_chunk_nonce), which is never used twice.
dm_seal_with :: proc(
	key: ^[DM_KEY_SIZE]u8,
	from, to: [KEY_SIZE]u8,
	id: u64,
	part: DM_Part,
	nonce: [DM_NONCE_SIZE]u8,
	data: []u8,
	out: []u8,
) -> []u8 {
	nonce := nonce
	aad_buf: [DM_AAD_SIZE]u8
	n := len(data)
	aead.seal_oneshot(
		.XCHACHA20POLY1305,
		out[:n],
		out[n:][:TAG_SIZE],
		key[:],
		nonce[:],
		dm_aad(&aad_buf, from, to, id, part),
		data,
	)
	return out[:n + TAG_SIZE]
}

// dm_open decrypts something dm_seal sealed into `out`, which needs
// len(sealed) - TAG_SIZE bytes.
dm_open :: proc(
	key: ^[DM_KEY_SIZE]u8,
	from, to: [KEY_SIZE]u8,
	id: u64,
	part: DM_Part,
	nonce: [DM_NONCE_SIZE]u8,
	sealed: []u8,
	out: []u8,
) -> (
	data: []u8,
	ok: bool,
) {
	nonce := nonce
	if len(sealed) < TAG_SIZE || len(sealed) - TAG_SIZE > len(out) {
		return
	}
	n := len(sealed) - TAG_SIZE
	aad_buf: [DM_AAD_SIZE]u8
	if !aead.open_oneshot(
		.XCHACHA20POLY1305,
		out[:n],
		key[:],
		nonce[:],
		dm_aad(&aad_buf, from, to, id, part),
		sealed[:n],
		sealed[n:],
	) {
		return
	}
	return out[:n], true
}

// encode_dm_text writes a text DM's body; the text should be sanitized
// and at most MAX_DM_SIZE bytes.
encode_dm_text :: proc(out: ^[MAX_DM_BODY]u8, text: string) -> []u8 {
	n := min(len(text), MAX_DM_SIZE)
	out[0] = u8(DM_Content.Text)
	copy(out[1:], text[:n])
	return out[:1 + n]
}

encode_dm_image :: proc(out: ^[MAX_DM_BODY]u8, img: DM_Image) -> []u8 {
	img := img
	out[0] = u8(DM_Content.Image)
	endian.unchecked_put_u16le(out[1:], img.width)
	endian.unchecked_put_u16le(out[3:], img.height)
	endian.unchecked_put_u32le(out[5:], img.size)
	copy(out[9:], img.nonce[:])
	return out[:DM_IMAGE_BODY_SIZE]
}

// decode_dm_body reads an opened body. The text and the file's name
// aren't sanitized yet.
@(require_results)
decode_dm_body :: proc(
	body: []u8,
) -> (
	content: DM_Content,
	text: string,
	img: DM_Image,
	file: DM_File,
	ok: bool,
) {
	if len(body) == 0 {
		return
	}
	content = DM_Content(body[0])
	switch content {
	case .Text:
		return content, string(body[1:]), {}, {}, true
	case .File:
		file, ok = decode_dm_file(body)
		return
	case .Image:
		if len(body) != DM_IMAGE_BODY_SIZE {
			return
		}
		img.width = endian.unchecked_get_u16le(body[1:])
		img.height = endian.unchecked_get_u16le(body[3:])
		img.size = endian.unchecked_get_u32le(body[5:])
		copy(img.nonce[:], body[9:])
		ok = img.width > 0 && img.height > 0 && img.size > TAG_SIZE && img.size <= MAX_DM_IMAGE_SEALED
		return
	}
	return
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

encode_dm_image_send :: proc(
	out: []u8,
	id: u64,
	to: [KEY_SIZE]u8,
	nonce: [DM_NONCE_SIZE]u8,
	image_size: int,
	sealed: []u8,
) -> []u8 {
	to, nonce := to, nonce
	out[0] = u8(Message_Kind.DM_Image_Send)
	endian.unchecked_put_u64le(out[1:], id)
	copy(out[9:], to[:])
	copy(out[9 + KEY_SIZE:], nonce[:])
	endian.unchecked_put_u32le(out[DM_SEND_HEADER_SIZE:], u32(image_size))
	copy(out[DM_IMAGE_SEND_HEADER_SIZE:], sealed)
	return out[:DM_IMAGE_SEND_HEADER_SIZE + len(sealed)]
}

// decode_dm_image_send reads a DM_Image_Send; message_kind has checked
// the size.
decode_dm_image_send :: proc(
	pt: []u8,
) -> (
	id: u64,
	to: [KEY_SIZE]u8,
	nonce: [DM_NONCE_SIZE]u8,
	image_size: int,
	sealed: []u8,
) {
	id = endian.unchecked_get_u64le(pt[1:])
	copy(to[:], pt[9:])
	copy(nonce[:], pt[9 + KEY_SIZE:])
	image_size = int(endian.unchecked_get_u32le(pt[DM_SEND_HEADER_SIZE:]))
	sealed = pt[DM_IMAGE_SEND_HEADER_SIZE:]
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
// DM_Ack, DM_Image_Get and DM_Image_Gone (the sender's key) and
// DM_Delivered (the recipient's).
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
