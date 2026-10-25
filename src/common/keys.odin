package common

import log "common:wlog"
import "core:crypto/ecdh"
import "core:encoding/hex"
import "core:strings"

import "common:proto"

// generate_private_key returns a new private key in hex, which is the
// format keys are stored in.
generate_private_key :: proc(allocator := context.allocator) -> (encoded: string, ok: bool) {
	key: ecdh.Private_Key
	if !ecdh.private_key_generate(&key, .X25519) {
		log.error("failed to generate key")
		return
	}
	defer ecdh.private_key_clear(&key)

	raw: [proto.KEY_SIZE]byte
	ecdh.private_key_bytes(&key, raw[:])
	return string(hex.encode(raw[:], allocator)), true
}

// parse_private_key sets `key` from its hex form. Surrounding whitespace
// is ignored.
parse_private_key :: proc(encoded: string, key: ^ecdh.Private_Key) -> bool {
	raw, ok := hex.decode(transmute([]byte)strings.trim_space(encoded), context.temp_allocator)
	return ok && len(raw) == proto.KEY_SIZE && ecdh.private_key_set_bytes(key, .X25519, raw)
}

// keygen generates a private key and stores it at `path` as a single line
// of hex that only the owner can read.
keygen :: proc(path: string) -> bool {
	encoded := generate_private_key(context.temp_allocator) or_return
	if !store_write(path, encoded, private = true) {
		return false
	}

	log.infof("generated a new private key in %s", path)
	return true
}

// load_or_create_private_key loads the key at `path`. If the file doesn't
// exist yet, a new key is generated and stored there first.
load_or_create_private_key :: proc(path: string, key: ^ecdh.Private_Key) -> bool {
	if !store_exists(path) && !keygen(path) {
		return false
	}
	return load_private_key(path, key)
}

load_private_key :: proc(path: string, key: ^ecdh.Private_Key) -> bool {
	data, read_ok := store_read(path, context.temp_allocator)
	if !read_ok {
		return false
	}
	if !parse_private_key(data, key) {
		log.errorf("%s is not a valid private key", path)
		return false
	}
	return true
}

public_key_hex :: proc(key: ^ecdh.Private_Key) -> string {
	raw: [proto.KEY_SIZE]byte
	ecdh.private_key_public_bytes(key, raw[:])
	return key_hex(raw)
}

// key_hex returns a public key as hex, allocated with the temp allocator: the
// form keys are written in (settings, known_servers, the server's log of its
// own key).
key_hex :: proc(key: [proto.KEY_SIZE]byte) -> string {
	key := key
	return string(hex.encode(key[:], context.temp_allocator))
}

// parse_key_hex reads a public key as key_hex writes it: 2 * KEY_SIZE hex
// digits.
parse_key_hex :: proc(s: string) -> (key: [proto.KEY_SIZE]byte, ok: bool) {
	if len(s) != 2 * proto.KEY_SIZE {
		return
	}
	raw := hex.decode(transmute([]u8)s, context.temp_allocator) or_return
	copy(key[:], raw)
	return key, true
}

// key_id returns a short, stable display id for a peer. It is made of the
// first 4 bytes of the peer's public key, so printing it with `%08x`
// matches the start of the hex key.
key_id :: proc(pub: [proto.KEY_SIZE]byte) -> u32 {
	return u32(pub[0]) << 24 | u32(pub[1]) << 16 | u32(pub[2]) << 8 | u32(pub[3])
}
