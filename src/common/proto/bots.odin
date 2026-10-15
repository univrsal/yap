package proto

import "core:crypto/ecdh"
import "core:encoding/base64"
import "core:strings"

// Bot accounts: accounts for programs (docs/bot-api). A bot is an account with
// the Bot flag (accounts.odin) that is created by an admin (Manage_Accounts).
// Like any account, it can do whatever its roles allow.
//
// It has no password, so it can't log in with Auth_Login and can't change or be
// given a password. It logs in with tokens instead, and each token is a device
// of its own. The admin's client generates the device's key, sends only the
// public half to the server and shows the private half once, as the token.
// The server never sees a token. A token's device is listed (Device_List with
// the bot's account) and logged out (Device_Revoke) like any other device.
//
// 	Bot_Create     [username str8][display str8][key 32][device str8]
// 	           ->  [account u32]
// 	Bot_Token_Add  [account u32][key 32][device str8]
//
// `key` is the token's public key and `device` is the name of its device in
// the bot's list. The answer is Conflict if the key already belongs to a
// device or if the username is taken.
//
// A bot can't join a voice room or a call (Denied). Everything else works as
// for any other account.
//
// A token is "yap_" followed by its private key in base64url without padding.

BOT_TOKEN_PREFIX :: "yap_"
// The prefix followed by 32 bytes in unpadded base64.
BOT_TOKEN_SIZE :: len(BOT_TOKEN_PREFIX) + 43

// The name of a token's device if the admin doesn't give one.
BOT_DEVICE_NAME :: "token"

BOT_BODY_MAX ::
	4 + (1 + MAX_USERNAME_SIZE) + (1 + MAX_NAME_SIZE) + KEY_SIZE + (1 + MAX_DEVICE_NAME)

encode_bot_create :: proc(
	out: []u8,
	username, display: string,
	key: [KEY_SIZE]u8,
	device: string,
) -> []u8 {
	key := key
	w := Writer {
		buf = out,
	}
	put_str8(&w, username)
	put_str8(&w, display)
	put_bytes(&w, key[:])
	put_str8(&w, device)
	return nil if w.overflow else out[:w.pos]
}

decode_bot_create :: proc(
	body: []u8,
) -> (
	username, display: string,
	key: [KEY_SIZE]u8,
	device: string,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	username = get_str8(&r)
	display = get_str8(&r)
	copy(key[:], get_bytes(&r, KEY_SIZE))
	device = get_str8(&r)
	return username, display, key, device, !r.overflow
}

encode_bot_token_add :: proc(
	out: []u8,
	account: Account_Id,
	key: [KEY_SIZE]u8,
	device: string,
) -> []u8 {
	key := key
	w := Writer {
		buf = out,
	}
	put_u32(&w, u32(account))
	put_bytes(&w, key[:])
	put_str8(&w, device)
	return nil if w.overflow else out[:w.pos]
}

decode_bot_token_add :: proc(
	body: []u8,
) -> (
	account: Account_Id,
	key: [KEY_SIZE]u8,
	device: string,
	ok: bool,
) {
	r := Reader {
		buf = body,
	}
	account = Account_Id(get_u32(&r))
	copy(key[:], get_bytes(&r, KEY_SIZE))
	device = get_str8(&r)
	return account, key, device, !r.overflow
}

// bot_token_make makes a new token. It returns the private key as the token
// to show to the admin (allocated with `allocator`) and the public key to send
// to the server. It returns false if no key could be generated.
bot_token_make :: proc(
	allocator := context.allocator,
) -> (
	token: string,
	public: [KEY_SIZE]u8,
	ok: bool,
) {
	key: ecdh.Private_Key
	if !ecdh.private_key_generate(&key, .X25519) {
		return
	}
	defer ecdh.private_key_clear(&key)
	raw: [KEY_SIZE]u8
	defer zero_bytes(raw[:])
	ecdh.private_key_bytes(&key, raw[:])
	ecdh.private_key_public_bytes(&key, public[:])

	encoded: [48]u8
	defer zero_bytes(encoded[:])
	text, err := base64.encode_into_buf(encoded[:], raw[:], base64.ENC_URL_TABLE)
	if err != nil {
		return
	}
	text_s := strings.trim_right(string(text), "=")
	return strings.concatenate({BOT_TOKEN_PREFIX, text_s}, allocator), public, true
}

// bot_token_parse sets `key` from a token, ignoring surrounding whitespace.
// It returns false if `raw` is not a valid token.
bot_token_parse :: proc(raw: string, key: ^ecdh.Private_Key) -> bool {
	token := strings.trim_space(raw)
	if len(token) != BOT_TOKEN_SIZE || !strings.has_prefix(token, BOT_TOKEN_PREFIX) {
		return false
	}
	padded: [44]u8
	defer zero_bytes(padded[:])
	copy(padded[:], token[len(BOT_TOKEN_PREFIX):])
	padded[43] = '='
	raw: [KEY_SIZE + 2]u8
	defer zero_bytes(raw[:])
	decoded, err := base64.decode_into_buf(raw[:], string(padded[:]), base64.DEC_URL_TABLE)
	if err != nil || len(decoded) != KEY_SIZE {
		return false
	}
	return ecdh.private_key_set_bytes(key, .X25519, decoded)
}

@(private = "file")
zero_bytes :: proc(b: []u8) {
	for &x in b {
		x = 0
	}
}
