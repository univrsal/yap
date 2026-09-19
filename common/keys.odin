package common

import "core:crypto/ecdh"
import "core:encoding/hex"
import "core:log"
import "core:os"
import "core:strings"

import "../proto"

// Private keys are stored as a single line of hex, readable only by the owner.
keygen :: proc(path: string) -> bool {
	key: ecdh.Private_Key
	if !ecdh.private_key_generate(&key, .X25519) {
		log.error("failed to generate key")
		return false
	}
	defer ecdh.private_key_clear(&key)

	raw: [proto.KEY_SIZE]byte
	ecdh.private_key_bytes(&key, raw[:])
	encoded := hex.encode(raw[:], context.temp_allocator)
	if err := os.write_entire_file(path, encoded, os.Permissions{.Read_User, .Write_User});
	   err != nil {
		log.errorf("failed to write %s: %v", path, err)
		return false
	}

	log.infof("generated a new private key in %s", path)
	return true
}

// load_or_create_private_key loads `path`, generating a new key there
// first if the file doesn't exist yet.
load_or_create_private_key :: proc(path: string, key: ^ecdh.Private_Key) -> bool {
	if !os.exists(path) && !keygen(path) {
		return false
	}
	return load_private_key(path, key)
}

load_private_key :: proc(path: string, key: ^ecdh.Private_Key) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("failed to read %s: %v", path, err)
		return false
	}
	raw, ok := hex.decode(
		transmute([]byte)strings.trim_space(string(data)),
		context.temp_allocator,
	)
	if !ok || len(raw) != proto.KEY_SIZE || !ecdh.private_key_set_bytes(key, .X25519, raw) {
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
