package proto

import "core:encoding/endian"

/*
A poke: one user nudging another, which their client shows as a desktop
notification, with a short message if the poker wrote one.

	kind (1) | sender user (4) | target user (4) | length (1) | message (UTF-8, 0-255)

The same message goes both ways. From a client, the sender is ignored:
the server fills in whoever's session it came on, so nobody can poke in
someone else's name. It's sent once, like Typing - a poke that gets lost
is a poke that didn't happen.
*/

MAX_POKE_SIZE :: 255 // bytes of UTF-8, as the length is one byte
POKE_HEADER_SIZE :: 10
POKE_MAX_SIZE :: POKE_HEADER_SIZE + MAX_POKE_SIZE

encode_poke :: proc(out: ^[POKE_MAX_SIZE]u8, sender, target: User_Num, msg: string) -> []u8 {
	n := min(len(msg), MAX_POKE_SIZE)
	out[0] = u8(Message_Kind.Poke)
	endian.unchecked_put_u32le(out[1:], u32(sender))
	endian.unchecked_put_u32le(out[5:], u32(target))
	out[9] = u8(n)
	copy(out[POKE_HEADER_SIZE:], msg[:n])
	return out[:POKE_HEADER_SIZE + n]
}

// decode_poke reads a Poke; message_kind has checked the size. The
// message points into `pt`.
decode_poke :: proc(pt: []u8) -> (sender, target: User_Num, msg: string) {
	sender = User_Num(endian.unchecked_get_u32le(pt[1:]))
	target = User_Num(endian.unchecked_get_u32le(pt[5:]))
	msg = string(pt[POKE_HEADER_SIZE:][:int(pt[9])])
	return
}
