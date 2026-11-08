package webpush

import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/json"
import "core:strings"
import "core:testing"

import "../curl"

// Tests of Web Push's cryptography (crypto.odin) against the examples in the
// RFCs, and of the checks that keep a push from reaching private addresses.

@(private = "file")
decode64 :: proc(t: ^testing.T, s: string) -> []u8 {
	data, ok := base64url_decode(s, context.temp_allocator)
	testing.expectf(t, ok, "%q is not base64url", s)
	return data
}

// The example of RFC 8291, appendix A.
@(private = "file")
RFC_PLAINTEXT :: "When I grow up, I want to be a watermelon"
@(private = "file")
RFC_AS_PRIVATE :: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
@(private = "file")
RFC_UA_PUBLIC :: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
@(private = "file")
RFC_AUTH :: "BTBZMqHH6r4Tts7J_aSIgg"
@(private = "file")
RFC_SALT :: "DGv6ra1nlYgDCS1FRnbzlw"
@(private = "file")
RFC_BODY :: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

@(test)
test_encrypt_rfc8291_example :: proc(t: ^testing.T) {
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	testing.expect(t, ecdh.private_key_set_bytes(&key, .SECP256R1, decode64(t, RFC_AS_PRIVATE)))
	body, ok := encrypt_with(
		transmute([]u8)string(RFC_PLAINTEXT),
		decode64(t, RFC_UA_PUBLIC),
		decode64(t, RFC_AUTH),
		&key,
		decode64(t, RFC_SALT),
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, base64url(body, context.temp_allocator), RFC_BODY)
}

// decrypt is what a browser does: it opens a body with the subscription's
// private key and auth secret.
@(private = "file")
decrypt :: proc(
	t: ^testing.T,
	body: []u8,
	ua: ^ecdh.Private_Key,
	auth: []u8,
) -> (
	plaintext: []u8,
	ok: bool,
) {
	if len(body) < PUSH_HEADER_SIZE + 1 + PUSH_TAG_SIZE {
		return
	}
	salt := body[:PUSH_SALT_SIZE]
	as_public := body[PUSH_SALT_SIZE + 5:PUSH_HEADER_SIZE]
	as_key: ecdh.Public_Key
	ecdh.public_key_set_bytes(&as_key, .SECP256R1, as_public) or_return
	shared: [32]u8
	ecdh.ecdh(ua, &as_key, shared[:]) or_return
	ua_public: [P256_PUBLIC_SIZE]u8
	ecdh.private_key_public_bytes(ua, ua_public[:])

	info := make([dynamic]u8, context.temp_allocator)
	append(&info, ..transmute([]u8)string("WebPush: info\x00"))
	append(&info, ..ua_public[:])
	append(&info, ..as_public)
	ikm: [32]u8
	hkdf.extract_and_expand(.SHA256, auth, shared[:], info[:], ikm[:])
	prk: [32]u8
	hkdf.extract(.SHA256, salt, ikm[:], prk[:])
	cek: [16]u8
	hkdf.expand(.SHA256, prk[:], transmute([]u8)string("Content-Encoding: aes128gcm\x00"), cek[:])
	nonce: [12]u8
	hkdf.expand(.SHA256, prk[:], transmute([]u8)string("Content-Encoding: nonce\x00"), nonce[:])

	record := body[PUSH_HEADER_SIZE:]
	n := len(record) - PUSH_TAG_SIZE
	out := make([]u8, n, context.temp_allocator)
	aead.open_oneshot(.AES_GCM_128, out, cek[:], nonce[:], nil, record[:n], record[n:]) or_return
	// The last record ends with the delimiter 2, after any padding.
	end := n
	for end > 0 && out[end - 1] == 0 {
		end -= 1
	}
	if end == 0 || out[end - 1] != 2 {
		return
	}
	return out[:end - 1], true
}

@(test)
test_encrypt_can_be_decrypted :: proc(t: ^testing.T) {
	ua: ecdh.Private_Key
	defer ecdh.private_key_clear(&ua)
	testing.expect(t, ecdh.private_key_generate(&ua, .SECP256R1))
	ua_public: [P256_PUBLIC_SIZE]u8
	ecdh.private_key_public_bytes(&ua, ua_public[:])
	auth: [PUSH_AUTH_SIZE]u8
	for &b, i in auth {
		b = u8(i * 7 + 1)
	}

	for text in ([]string {
			"",
			"x",
			RFC_PLAINTEXT,
			strings.repeat("é", 1000, context.temp_allocator),
		}) {
		body, ok := encrypt(transmute([]u8)text, ua_public[:], auth[:], context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, len(body), PUSH_HEADER_SIZE + len(text) + 1 + PUSH_TAG_SIZE)
		plain, opened := decrypt(t, body, &ua, auth[:])
		testing.expectf(t, opened, "a body of %d bytes could not be opened", len(text))
		testing.expect_value(t, string(plain), text)

		// The header says how it is coded: a record of 4096 bytes with the
		// sender's 65-byte key as its id.
		testing.expect_value(t, body[PUSH_SALT_SIZE], u8(0))
		testing.expect_value(t, body[PUSH_SALT_SIZE + 1], u8(0))
		testing.expect_value(t, body[PUSH_SALT_SIZE + 2], u8(16))
		testing.expect_value(t, body[PUSH_SALT_SIZE + 3], u8(0))
		testing.expect_value(t, body[PUSH_SALT_SIZE + 4], u8(P256_PUBLIC_SIZE))
		testing.expect_value(t, body[PUSH_SALT_SIZE + 5], u8(4)) // an uncompressed point

		// Only the right auth secret opens it, and a changed body doesn't open at all.
		wrong := auth
		wrong[0] ~= 1
		_, opened = decrypt(t, body, &ua, wrong[:])
		testing.expect(t, !opened, "opened with the wrong auth secret")
		tampered := make([]u8, len(body), context.temp_allocator)
		copy(tampered, body)
		tampered[len(tampered) - 1] ~= 1
		_, opened = decrypt(t, tampered, &ua, auth[:])
		testing.expect(t, !opened, "a changed body was accepted")
	}

	// Every message uses a fresh key and salt.
	a, _ := encrypt(transmute([]u8)string("same"), ua_public[:], auth[:], context.temp_allocator)
	b, _ := encrypt(transmute([]u8)string("same"), ua_public[:], auth[:], context.temp_allocator)
	testing.expect(t, string(a[:PUSH_SALT_SIZE]) != string(b[:PUSH_SALT_SIZE]))
	testing.expect(t, string(a) != string(b))
}

@(test)
test_encrypt_limits :: proc(t: ^testing.T) {
	ua: ecdh.Private_Key
	defer ecdh.private_key_clear(&ua)
	testing.expect(t, ecdh.private_key_generate(&ua, .SECP256R1))
	ua_public: [P256_PUBLIC_SIZE]u8
	ecdh.private_key_public_bytes(&ua, ua_public[:])
	auth: [PUSH_AUTH_SIZE]u8

	// The largest payload fits in the 4096 bytes push services accept.
	most := make([]u8, PUSH_PAYLOAD_MOST, context.temp_allocator)
	body, ok := encrypt(most, ua_public[:], auth[:], context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(body), 4096)
	_, ok = encrypt(
		make([]u8, PUSH_PAYLOAD_MOST + 1, context.temp_allocator),
		ua_public[:],
		auth[:],
		context.temp_allocator,
	)
	testing.expect(t, !ok, "a payload that is too long was encrypted")

	// A key that isn't 65 bytes, isn't a point on the curve, or is compressed.
	for bad_key in ([][]u8 {
			ua_public[:64],
			ua_public[:0],
			make([]u8, P256_PUBLIC_SIZE, context.temp_allocator), // all zero
		}) {
		_, ok = encrypt(transmute([]u8)string("hi"), bad_key, auth[:], context.temp_allocator)
		testing.expect(t, !ok, "a bad key was accepted")
	}
	off_curve := ua_public
	off_curve[P256_PUBLIC_SIZE - 1] ~= 1
	_, ok = encrypt(transmute([]u8)string("hi"), off_curve[:], auth[:], context.temp_allocator)
	testing.expect(t, !ok, "a point that isn't on the curve was accepted")

	// An auth secret that isn't 16 bytes.
	_, ok = encrypt(transmute([]u8)string("hi"), ua_public[:], auth[:15], context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = encrypt(transmute([]u8)string("hi"), ua_public[:], nil, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_base64url :: proc(t: ^testing.T) {
	// Without padding, and with the URL alphabet.
	testing.expect_value(t, base64url(nil, context.temp_allocator), "")
	testing.expect_value(t, base64url([]u8{0xfb, 0xff}, context.temp_allocator), "-_8")
	testing.expect_value(t, base64url([]u8{1}, context.temp_allocator), "AQ")
	testing.expect_value(t, base64url([]u8{1, 2}, context.temp_allocator), "AQI")
	testing.expect_value(t, base64url([]u8{1, 2, 3}, context.temp_allocator), "AQID")

	for size in 0 ..< 70 {
		data := make([]u8, size, context.temp_allocator)
		for &b, i in data {
			b = u8(i * 37 + 11)
		}
		encoded := base64url(data, context.temp_allocator)
		testing.expect(t, !strings.contains_any(encoded, "=+/"))
		decoded, ok := base64url_decode(encoded, context.temp_allocator)
		testing.expectf(t, ok && string(decoded) == string(data), "%d bytes", size)
	}

	// Padding is accepted too, which some subscriptions have.
	decoded, ok := base64url_decode("AQI=", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(decoded), 2)
	for bad in ([]string{"A", "AQ!D", "AQI$", "A Q I"}) {
		_, ok = base64url_decode(bad, context.temp_allocator)
		testing.expectf(t, !ok, "%q was accepted", bad)
	}
}

@(test)
test_vapid_key :: proc(t: ^testing.T) {
	encoded, ok := vapid_key_generate(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(encoded), 2 * P256_PRIVATE_SIZE)
	other, _ := vapid_key_generate(context.temp_allocator)
	testing.expect(t, encoded != other, "two keys are the same")

	key: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&key)
	testing.expect(t, vapid_key_parse(encoded, &key))
	// The config file may have whitespace around it.
	key2: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&key2)
	testing.expect(
		t,
		vapid_key_parse(strings.concatenate({"  ", encoded, "\n"}, context.temp_allocator), &key2),
	)
	testing.expect(t, ecdsa.private_key_equal(&key, &key2))

	for bad in ([]string {
			"",
			"zz",
			encoded[:len(encoded) - 2],
			strings.concatenate({encoded, "00"}, context.temp_allocator),
			strings.repeat("g", 64, context.temp_allocator),
			strings.repeat("0", 64, context.temp_allocator), // not a valid scalar
		}) {
		var: ecdsa.Private_Key
		testing.expectf(t, !vapid_key_parse(bad, &var), "%q was accepted", bad)
	}
}

@(test)
test_vapid_jwt :: proc(t: ^testing.T) {
	encoded, _ := vapid_key_generate(context.temp_allocator)
	key: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&key)
	testing.expect(t, vapid_key_parse(encoded, &key))
	pub: ecdsa.Public_Key
	defer ecdsa.public_key_clear(&pub)
	ecdsa.public_key_set_priv(&pub, &key)

	jwt := vapid_jwt(
		&key,
		"https://push.example.org",
		"mailto:ops@example.org",
		1_800_000_000,
		context.temp_allocator,
	)
	parts := strings.split(jwt, ".", context.temp_allocator)
	testing.expect_value(t, len(parts), 3)
	if len(parts) != 3 {
		return
	}
	// The fixed header is the one for ES256.
	testing.expect_value(t, string(decode64(t, parts[0])), `{"typ":"JWT","alg":"ES256"}`)

	claims: struct {
		aud: string,
		exp: i64,
		sub: string,
	}
	testing.expect(
		t,
		json.unmarshal(decode64(t, parts[1]), &claims, allocator = context.temp_allocator) == nil,
	)
	testing.expect_value(t, claims.aud, "https://push.example.org")
	testing.expect_value(t, claims.exp, i64(1_800_000_000))
	testing.expect_value(t, claims.sub, "mailto:ops@example.org")

	// The signature is the raw r and s of ES256 over the first two parts, and
	// the public key the browser was given verifies it.
	sig := decode64(t, parts[2])
	testing.expect_value(t, len(sig), 2 * P256_PRIVATE_SIZE)
	signed := strings.concatenate({parts[0], ".", parts[1]}, context.temp_allocator)
	testing.expect(t, ecdsa.verify_raw(&pub, .SHA256, transmute([]u8)signed, sig))
	tampered := strings.concatenate({parts[0], ".", parts[1], "x"}, context.temp_allocator)
	testing.expect(t, !ecdsa.verify_raw(&pub, .SHA256, transmute([]u8)tampered, sig))

	// Names are quoted, so that a subject can't add claims of its own.
	jwt = vapid_jwt(
		&key,
		"https://a.example",
		`mailto:x@y","exp":1,"z":"`,
		5,
		context.temp_allocator,
	)
	parts = strings.split(jwt, ".", context.temp_allocator)
	testing.expect_value(t, len(parts), 3)
	if len(parts) == 3 {
		var: struct {
			aud: string,
			exp: i64,
			sub: string,
		}
		testing.expect(
			t,
			json.unmarshal(decode64(t, parts[1]), &var, allocator = context.temp_allocator) == nil,
		)
		testing.expect_value(t, var.exp, i64(5))
		testing.expect_value(t, var.sub, `mailto:x@y","exp":1,"z":"`)
	}
}

@(test)
test_origin :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		origin("https://push.example.org/send/abc"),
		"https://push.example.org",
	)
	testing.expect_value(
		t,
		origin("https://push.example.org:8443/x"),
		"https://push.example.org:8443",
	)
	testing.expect_value(t, origin("https://a/"), "https://a")

	for bad in ([]string {
			"",
			"http://push.example.org/send",
			"https://",
			"https:///path",
			"https://push.example.org", // no path
			"ftp://push.example.org/x",
			"HTTPS://push.example.org/x",
			"https://push example.org/x",
			"https://push.example.org/a b",
			"https://push.example.org/a\"b",
			"https://push.example.org/a\\b",
			"https://push.example.org/a\nb",
			"https://push.example.org/é",
			strings.concatenate(
				{"https://push.example.org/", strings.repeat("a", 2048, context.temp_allocator)},
				context.temp_allocator,
			),
		}) {
		testing.expectf(t, origin(bad) == "", "%q was accepted", bad)
	}
}

@(private = "file")
v4 :: proc(a, b, c, d: u8) -> bool {
	sa: [16]u8 // a struct sockaddr_in: the family and port, then the address
	sa[4], sa[5], sa[6], sa[7] = a, b, c, d
	return address_public(curl.AF_INET, sa[:])
}

@(private = "file")
v6 :: proc(addr: [16]u8) -> bool {
	addr := addr
	sa: [28]u8 // a struct sockaddr_in6: family, port, flow info, then the address
	copy(sa[8:], addr[:])
	return address_public(curl.AF_INET6, sa[:])
}

@(test)
test_pushes_only_go_to_public_ipv4 :: proc(t: ^testing.T) {
	public := [][4]u8 {
		{8, 8, 8, 8},
		{1, 1, 1, 1},
		{172, 15, 0, 1}, // just below 172.16.0.0/12
		{172, 32, 0, 1}, // just above it
		{100, 63, 255, 255}, // just below 100.64.0.0/10
		{100, 128, 0, 0}, // just above it
		{169, 253, 255, 255},
		{169, 255, 0, 0},
		{192, 167, 0, 1},
		{192, 169, 0, 1},
		{198, 17, 255, 255}, // just below 198.18.0.0/15
		{198, 20, 0, 0}, // just above it
		{223, 255, 255, 255},
		{11, 0, 0, 1},
		{126, 255, 255, 255},
		{128, 0, 0, 1},
	}
	for a in public {
		testing.expectf(t, v4(a[0], a[1], a[2], a[3]), "%v was refused", a)
	}
	private := [][4]u8 {
		{0, 0, 0, 0},
		{10, 0, 0, 1},
		{10, 255, 255, 255},
		{127, 0, 0, 1},
		{127, 255, 255, 254},
		{100, 64, 0, 1}, // shared (CGNAT)
		{100, 127, 255, 255},
		{169, 254, 169, 254}, // link-local, where cloud metadata is
		{172, 16, 0, 1},
		{172, 31, 255, 255},
		{192, 168, 1, 1},
		{192, 0, 0, 8},
		{198, 18, 0, 1}, // benchmarking
		{198, 19, 255, 255},
		{224, 0, 0, 1}, // multicast
		{239, 255, 255, 250},
		{240, 0, 0, 1}, // reserved
		{255, 255, 255, 255},
	}
	for a in private {
		testing.expectf(t, !v4(a[0], a[1], a[2], a[3]), "%v was allowed", a)
	}
}

// a6 makes an IPv6 address from its first bytes and its last.
@(private = "file")
a6 :: proc(head: []u8, last: u8) -> (a: [16]u8) {
	copy(a[:], head)
	a[15] = last
	return
}

@(test)
test_pushes_only_go_to_public_ipv6 :: proc(t: ^testing.T) {
	// 2606:4700::1111 (a public resolver).
	testing.expect(t, v6(a6({0x26, 0x06, 0x47, 0x00}, 0x11)))
	testing.expect(t, v6(a6({0x20, 0x01, 0x48, 0x60, 0x48, 0x60}, 0x88))) // 2001:4860:4860::88
	testing.expect(t, v6(a6({0x20, 0x01, 0x0d, 0xb9}, 1))) // next to the documentation range

	refused := [][16]u8 {
		{15 = 1}, // ::1
		{}, // ::
		a6({0xfc, 0x00}, 1), // unique local
		a6({0xfd, 0x12, 0x34}, 1),
		a6({0xfe, 0x80}, 1), // link-local
		a6({0xfe, 0xbf}, 1),
		a6({0xfe, 0xc0}, 1), // site-local
		a6({0xff, 0x02}, 1), // multicast
		a6({0x20, 0x01, 0x0d, 0xb8}, 1), // documentation
		// IPv4 addresses inside IPv6 ones are judged as IPv4.
		{10 = 0xff, 11 = 0xff, 12 = 127, 15 = 1}, // ::ffff:127.0.0.1
		{10 = 0xff, 11 = 0xff, 12 = 10, 15 = 1}, // ::ffff:10.0.0.1
		{10 = 0xff, 11 = 0xff, 12 = 169, 13 = 254, 14 = 169, 15 = 254}, // ::ffff:169.254.169.254
		{1 = 0x64, 2 = 0xff, 3 = 0x9b, 12 = 192, 13 = 168, 15 = 1}, // 64:ff9b::192.168.0.1
		a6({0x20, 0x02, 127, 0, 0, 1}, 1), // 6to4 of 127.0.0.1
		a6({0x20, 0x02, 10, 1, 2, 3}, 1), // 6to4 of 10.1.2.3
	}
	for a in refused {
		testing.expectf(t, !v6(a), "%v was allowed", a)
	}
	allowed_embedded := [][16]u8 {
		{10 = 0xff, 11 = 0xff, 12 = 8, 13 = 8, 14 = 8, 15 = 8}, // ::ffff:8.8.8.8
		{1 = 0x64, 2 = 0xff, 3 = 0x9b, 12 = 8, 13 = 8, 14 = 4, 15 = 4}, // 64:ff9b::8.8.4.4
		a6({0x20, 0x02, 8, 8, 8, 8}, 1), // 6to4 of 8.8.8.8
	}
	for a in allowed_embedded {
		testing.expectf(t, v6(a), "%v was refused", a)
	}
}

@(test)
test_address_public_malformed :: proc(t: ^testing.T) {
	// Unknown families, and addresses that were cut short, are never public.
	testing.expect(t, !address_public(0, make([]u8, 28, context.temp_allocator)))
	testing.expect(t, !address_public(curl.AF_INET, []u8{0, 0, 0, 0, 8, 8, 8}))
	testing.expect(t, !address_public(curl.AF_INET, nil))
	testing.expect(t, !address_public(curl.AF_INET6, make([]u8, 23, context.temp_allocator)))
	testing.expect(t, !address_public(curl.AF_INET6, nil))
}
