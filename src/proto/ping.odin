package proto

import "core:encoding/endian"

/*
Ping and Pong measure the connection, for the client to show how well
it's doing (see client/ping.odin).

	client -> server  Ping  [kind][id u32]
	server -> client  Pong  [kind][id u32]

The server answers every Ping with a Pong carrying the same id, on the
session the Ping came on. Both are unreliable and sent once: a ping
that gets no answer is exactly what's being counted. A server that
doesn't know Ping ignores it, and the client shows that it has nothing
to go on.
*/

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
