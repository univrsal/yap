package proto

import "core:encoding/endian"

// Ping and Pong measure the connection quality so that the client can show
// it (see client/ping.odin).
//
//	client -> server  Ping  [kind][id u32]
//	server -> client  Pong  [kind][id u32]
//
// The server answers every Ping with a Pong that carries the same id, on the
// session the Ping arrived on. Both are unreliable and sent only once,
// because a ping that gets no answer is exactly what is being counted. A
// server that doesn't know Ping ignores it, and the client then shows that
// no measurement is available.

PING_SIZE :: 1 + 4

encode_ping :: proc(out: ^[PING_SIZE]byte, kind: Message_Kind, id: u32) -> []byte {
	out[0] = u8(kind)
	endian.unchecked_put_u32le(out[1:], id)
	return out[:]
}

// decode_ping reads a Ping or a Pong; message_kind has checked the size.
decode_ping :: proc(pt: []byte) -> (id: u32) {
	return endian.unchecked_get_u32le(pt[1:])
}
