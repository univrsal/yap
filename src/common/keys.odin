package common

import "core:crypto/ecdh"
import "core:encoding/hex"
import log "wlog"
import "core:strings"

import "../proto"

// generate_private_key returns a new private key as hex, the form keys
// are stored in.
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

// parse_private_key sets `key` from its hex form; surrounding whitespace
// is ignored.
parse_private_key :: proc(encoded: string, key: ^ecdh.Private_Key) -> bool {
	raw, ok := hex.decode(transmute([]byte)strings.trim_space(encoded), context.temp_allocator)
	return ok && len(raw) == proto.KEY_SIZE && ecdh.private_key_set_bytes(key, .X25519, raw)
}

// Private keys are stored as a single line of hex, readable only by the owner.
keygen :: proc(path: string) -> bool {
	encoded := generate_private_key(context.temp_allocator) or_return
	if !store_write(path, encoded, private = true) {
		return false
	}

	log.infof("generated a new private key in %s", path)
	return true
}

// load_or_create_private_key loads `path`, generating a new key there
// first if the file doesn't exist yet.
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
	return string(hex.encode(raw[:], context.temp_allocator))
}

// Short, stable display id for a peer: the first 4 bytes of its public
// key, so `%08x` of it matches the start of the hex key.
key_id :: proc(pub: [proto.KEY_SIZE]byte) -> u32 {
	return u32(pub[0]) << 24 | u32(pub[1]) << 16 | u32(pub[2]) << 8 | u32(pub[3])
}
