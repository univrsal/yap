package server

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:net"

/*
Just enough of WebSockets (RFC 6455) for the relay: the opening
handshake, and binary frames in both directions. The web client only
ever sends one packet per message, each well under a kilobyte and a
half, so fragmented messages aren't expected and aren't accepted.
*/

@(private = "file")
ACCEPT_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Nothing the client sends is anywhere near this; a frame that claims
// more is not one of ours.
MAX_FRAME :: 64 * 1024

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

// accept_key answers a client's Sec-WebSocket-Key, which is how it
// knows the server understood the upgrade.
accept_key :: proc(key: string, allocator := context.temp_allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)key)
	sha1.update(&ctx, transmute([]byte)string(ACCEPT_GUID))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

// Conn reads a TCP socket through a buffer, so the HTTP request and the
// frames after it can be taken apart piece by piece.
Conn :: struct {
	sock:  net.TCP_Socket,
	buf:   [8192]u8,
	start: int,
	end:   int,
}

// read_exact fills `out` completely, or reports that the peer went away.
read_exact :: proc(c: ^Conn, out: []u8) -> bool {
	done := 0
	for done < len(out) {
		if c.start == c.end {
			n, err := net.recv_tcp(c.sock, c.buf[:])
			if err != nil || n == 0 {
				return false
			}
			c.start, c.end = 0, n
		}
		n := copy(out[done:], c.buf[c.start:c.end])
		c.start += n
		done += n
	}
	return true
}

/*
read_frame reads one frame into `payload`, unmasked. Frames from a
browser are always masked; one that isn't, or that is bigger than
MAX_FRAME, ends the connection.
*/
read_frame :: proc(c: ^Conn, payload: []u8) -> (op: Opcode, n: int, ok: bool) {
	head: [2]u8
	read_exact(c, head[:]) or_return
	fin := head[0] & 0x80 != 0
	op = Opcode(head[0] & 0x0F)
	masked := head[1] & 0x80 != 0
	size := u64(head[1] & 0x7F)
	switch size {
	case 126:
		ext: [2]u8
		read_exact(c, ext[:]) or_return
		size = u64(endian.unchecked_get_u16be(ext[:]))
	case 127:
		ext: [8]u8
		read_exact(c, ext[:]) or_return
		size = endian.unchecked_get_u64be(ext[:])
	}
	if !fin || !masked || size > u64(min(MAX_FRAME, len(payload))) {
		return
	}
	mask: [4]u8
	read_exact(c, mask[:]) or_return
	n = int(size)
	read_exact(c, payload[:n]) or_return
	for &b, i in payload[:n] {
		b ~= mask[i % 4]
	}
	return op, n, true
}

// write_frame sends one unmasked frame, as a server's always are.
write_frame :: proc(sock: net.TCP_Socket, op: Opcode, payload: []u8) -> bool {
	head: [10]u8
	head[0] = 0x80 | u8(op)
	head_len := 2
	switch {
	case len(payload) < 126:
		head[1] = u8(len(payload))
	case len(payload) <= 0xFFFF:
		head[1] = 126
		endian.unchecked_put_u16be(head[2:], u16(len(payload)))
		head_len = 4
	case:
		head[1] = 127
		endian.unchecked_put_u64be(head[2:], u64(len(payload)))
		head_len = 10
	}
	return send_all(sock, head[:head_len]) && send_all(sock, payload)
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	for sent := 0; sent < len(data); {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}
