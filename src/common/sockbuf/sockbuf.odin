#+build !wasi
package sockbuf

import "core:net"

// set_buffer_size sets the receive or send buffer of a socket, to `bytes` or
// as close as the system allows, and says whether the system took it.
//
// This is not net.set_option(sock, .Receive_Buffer_Size, ...): for the buffer
// sizes it passes the system the address of its argument rather than the number
// (its integer switch has several types in one case, which leaves a copy of the
// `any` rather than of the value). The number is then arbitrary: on Linux the
// kernel clamps it to its maximum, which is about what is asked for anyway, but
// OpenBSD takes it (a send buffer of one byte, so every datagram is "too long").
set_buffer_size :: proc(sock: net.Any_Socket, receive: bool, bytes: int) -> bool {
	fd := net.any_socket_to_socket(sock)
	return _set_buffer_size(fd, receive, bytes)
}
