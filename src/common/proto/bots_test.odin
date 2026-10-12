#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:strings"
import "core:testing"

@(test)
test_bot_token :: proc(t: ^testing.T) {
	token, public, ok := bot_token_make(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(token), BOT_TOKEN_SIZE)
	testing.expect(t, strings.has_prefix(token, BOT_TOKEN_PREFIX))
	testing.expect(t, !strings.contains_any(token, "+/="))

	// It's the key the public half was made from, spaces around it or
	// not.
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	for text in ([]string{token, strings.concatenate({"  ", token, "\n"}, context.temp_allocator)}) {
		testing.expect(t, bot_token_parse(text, &key))
		got: [KEY_SIZE]u8
		ecdh.private_key_public_bytes(&key, got[:])
		testing.expect(t, got == public)
	}

	// Two are never the same.
	other, other_public, _ := bot_token_make(context.temp_allocator)
	testing.expect(t, other != token && other_public != public)

	for bad in ([]string {
			"",
			token[:len(token) - 1],
			strings.concatenate({token, "A"}, context.temp_allocator),
			strings.concatenate({"yip_", token[4:]}, context.temp_allocator),
			strings.concatenate({token[:10], "!", token[11:]}, context.temp_allocator),
		}) {
		testing.expect(t, !bot_token_parse(bad, &key))
	}
}

@(test)
test_bot_bodies :: proc(t: ^testing.T) {
	key: [KEY_SIZE]u8
	key[0], key[31] = 1, 2
	buf: [BOT_BODY_MAX]u8
	body := encode_bot_create(buf[:], "weather", "The weather", key, "laptop")
	username, display, got, device, ok := decode_bot_create(body)
	testing.expect(t, ok)
	testing.expect_value(t, username, "weather")
	testing.expect_value(t, display, "The weather")
	testing.expect(t, got == key)
	testing.expect_value(t, device, "laptop")
	_, _, _, _, ok = decode_bot_create(body[:len(body) - 1])
	testing.expect(t, !ok)

	body = encode_bot_token_add(buf[:], 7, key, "server")
	account, got2, device2, ok2 := decode_bot_token_add(body)
	testing.expect(t, ok2)
	testing.expect_value(t, account, Account_Id(7))
	testing.expect(t, got2 == key)
	testing.expect_value(t, device2, "server")
}
