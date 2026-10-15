package server

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"

// The cryptography for Web Push (push.odin), all of it implemented with core:crypto:
//
//   - A message is encrypted for the subscribed browser (RFC 8291, using RFC 8188's
//     aes128gcm content coding): a fresh P-256 key is generated for each message and
//     combined with the subscription's p256dh key via ECDH. The shared secret, mixed with
//     the subscription's auth secret, yields the key and nonce for a single AES-128-GCM
//     record.
//   - The server identifies itself with VAPID (RFC 8292): a JWT signed with ES256 using
//     the server's own P-256 key, which the browser was given when it subscribed. This way
//     the push service only accepts messages for that subscription from this server.

// The size of an uncompressed P-256 point, the format browsers use for p256dh and that is
// used for the VAPID public key: 0x04, followed by x and y.
P256_PUBLIC_SIZE :: 65
// The size of a P-256 private key's scalar.
P256_PRIVATE_SIZE :: 32
// The size of a subscription's auth secret.
PUSH_AUTH_SIZE :: 16
// The size of RFC 8188's header: the salt, the record size, the key id length, and the
// key id (the message's public key).
PUSH_HEADER_SIZE :: PUSH_SALT_SIZE + 4 + 1 + P256_PUBLIC_SIZE
PUSH_SALT_SIZE :: 16
// The record size that every implementation uses. A message always fits in one record.
PUSH_RECORD_SIZE :: 4096
PUSH_TAG_SIZE :: 16
// The largest payload: push services accept a body of at most 4096 bytes, minus the
// header, the padding delimiter and the tag.
PUSH_PAYLOAD_MOST :: 4096 - PUSH_HEADER_SIZE - 1 - PUSH_TAG_SIZE

// push_encrypt encrypts `plaintext` for a subscription (given its p256dh key and auth
// secret) with a fresh key and salt, and returns the body to POST, allocated with
// `allocator`. Returns false if the p256dh key isn't a point on P-256 or the plaintext is
// too long.
push_encrypt :: proc(
	plaintext: []u8,
	ua_public: []u8,
	auth: []u8,
	allocator := context.allocator,
) -> (
	body: []u8,
	ok: bool,
) {
	key: ecdh.Private_Key
	if !ecdh.private_key_generate(&key, .SECP256R1) {
		return
	}
	defer ecdh.private_key_clear(&key)
	salt: [PUSH_SALT_SIZE]u8
	crypto.rand_bytes(salt[:])
	return push_encrypt_with(plaintext, ua_public, auth, &key, salt[:], allocator)
}

// push_encrypt_with is push_encrypt with a caller-supplied key and salt, so the tests can
// use the ones from RFC 8291's example.
push_encrypt_with :: proc(
	plaintext: []u8,
	ua_public: []u8,
	auth: []u8,
	as_key: ^ecdh.Private_Key,
	salt: []u8,
	allocator := context.allocator,
) -> (
	body: []u8,
	ok: bool,
) {
	if len(plaintext) > PUSH_PAYLOAD_MOST ||
	   len(ua_public) != P256_PUBLIC_SIZE ||
	   len(auth) != PUSH_AUTH_SIZE ||
	   len(salt) != PUSH_SALT_SIZE {
		return
	}
	ua_key: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&ua_key, .SECP256R1, ua_public) {
		return
	}
	defer ecdh.public_key_clear(&ua_key)
	shared: [32]u8
	if !ecdh.ecdh(as_key, &ua_key, shared[:]) {
		return
	}
	defer crypto.zero_explicit(&shared, size_of(shared))
	as_public: [P256_PUBLIC_SIZE]u8
	ecdh.private_key_public_bytes(as_key, as_public[:])

	// RFC 8291 section 3.4: derive the input keying material from the shared secret, the
	// auth secret and both public keys.
	INFO :: "WebPush: info\x00"
	key_info: [len(INFO) + 2 * P256_PUBLIC_SIZE]u8
	copy(key_info[:], INFO)
	copy(key_info[len(INFO):], ua_public)
	copy(key_info[len(INFO) + P256_PUBLIC_SIZE:], as_public[:])
	ikm: [32]u8
	hkdf.extract_and_expand(.SHA256, auth, shared[:], key_info[:], ikm[:])
	defer crypto.zero_explicit(&ikm, size_of(ikm))

	// RFC 8188 sections 2.2 and 2.3: derive the content encryption key and the nonce,
	// using the salt.
	prk: [32]u8
	hkdf.extract(.SHA256, salt, ikm[:], prk[:])
	defer crypto.zero_explicit(&prk, size_of(prk))
	cek: [16]u8
	hkdf.expand(.SHA256, prk[:], transmute([]u8)string("Content-Encoding: aes128gcm\x00"), cek[:])
	defer crypto.zero_explicit(&cek, size_of(cek))
	nonce: [12]u8
	hkdf.expand(.SHA256, prk[:], transmute([]u8)string("Content-Encoding: nonce\x00"), nonce[:])

	// Write the header, followed by the single record: the plaintext, the delimiter that
	// marks the last record (2) and no padding, encrypted in place, followed by its tag.
	padded := len(plaintext) + 1
	body = make([]u8, PUSH_HEADER_SIZE + padded + PUSH_TAG_SIZE, allocator)
	copy(body, salt)
	put_u32_be(body[PUSH_SALT_SIZE:], PUSH_RECORD_SIZE)
	body[PUSH_SALT_SIZE + 4] = P256_PUBLIC_SIZE
	copy(body[PUSH_SALT_SIZE + 5:], as_public[:])
	record := body[PUSH_HEADER_SIZE:]
	copy(record, plaintext)
	record[len(plaintext)] = 2
	aead.seal_oneshot(
		.AES_GCM_128,
		record[:padded],
		record[padded:],
		cek[:],
		nonce[:],
		nil,
		record[:padded],
	)
	return body, true
}

@(private = "file")
put_u32_be :: proc(dst: []u8, v: u32) {
	dst[0] = u8(v >> 24)
	dst[1] = u8(v >> 16)
	dst[2] = u8(v >> 8)
	dst[3] = u8(v)
}

// The VAPID JWT header, {"typ":"JWT","alg":"ES256"}, already base64url-encoded.
@(private = "file")
VAPID_HEADER :: "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9"

// vapid_jwt creates the token that proves a message was sent by this server (RFC 8292).
// It is issued for the push service at `audience` (the endpoint's origin) and is valid
// until `expires` (Unix seconds; push services accept no more than a day ahead). `subject`
// is a mailto: or https: URL for contacting the server's operator. Allocated with
// `allocator`.
vapid_jwt :: proc(
	key: ^ecdsa.Private_Key,
	audience, subject: string,
	expires: i64,
	allocator := context.allocator,
) -> string {
	claims := strings.builder_make(context.temp_allocator)
	strings.write_string(&claims, `{"aud":`)
	strings.write_quoted_string(&claims, audience)
	strings.write_string(&claims, `,"exp":`)
	strings.write_i64(&claims, expires)
	strings.write_string(&claims, `,"sub":`)
	strings.write_quoted_string(&claims, subject)
	strings.write_string(&claims, "}")

	input := strings.concatenate(
		{
			VAPID_HEADER,
			".",
			base64url(transmute([]u8)strings.to_string(claims), context.temp_allocator),
		},
		context.temp_allocator,
	)
	sig: [2 * P256_PRIVATE_SIZE]u8
	if !ecdsa.sign_raw(key, .SHA256, transmute([]u8)input, sig[:]) {
		return ""
	}
	return strings.concatenate({input, ".", base64url(sig[:], context.temp_allocator)}, allocator)
}

// vapid_key_generate creates a new VAPID key, hex-encoded as it is stored in the config.
vapid_key_generate :: proc(allocator := context.allocator) -> (encoded: string, ok: bool) {
	key: ecdsa.Private_Key
	if !ecdsa.private_key_generate(&key, .SECP256R1) {
		return
	}
	defer ecdsa.private_key_clear(&key)
	raw: [P256_PRIVATE_SIZE]u8
	ecdsa.private_key_bytes(&key, raw[:])
	defer crypto.zero_explicit(&raw, size_of(raw))
	return string(hex.encode(raw[:], allocator)), true
}

// vapid_key_parse sets `key` from its hex-encoded form.
vapid_key_parse :: proc(encoded: string, key: ^ecdsa.Private_Key) -> bool {
	raw, ok := hex.decode(transmute([]u8)strings.trim_space(encoded), context.temp_allocator)
	return ok && len(raw) == P256_PRIVATE_SIZE && ecdsa.private_key_set_bytes(key, .SECP256R1, raw)
}

// base64url encodes `data` as base64url without padding, as required by JWTs and the Web
// Push headers.
base64url :: proc(data: []u8, allocator := context.allocator) -> string {
	encoded := base64.encode(data, base64.ENC_URL_TABLE, allocator)
	return strings.trim_right(encoded, "=")
}

// base64url_decode decodes base64url, with or without padding.
base64url_decode :: proc(s: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	padded := s
	if len(s) % 4 != 0 {
		padded = strings.concatenate(
			{s, strings.repeat("=", 4 - len(s) % 4, context.temp_allocator)},
			context.temp_allocator,
		)
	}
	out, err := base64.decode(padded, base64.DEC_URL_TABLE, allocator = allocator)
	return out, err == nil
}
