#+build linux
package sockbuf

import "core:net"
import "core:sys/linux"

@(private)
_set_buffer_size :: proc(sock: net.Socket, receive: bool, bytes: int) -> bool {
	value := i32(min(bytes, int(max(i32))))
	opt := linux.Socket_Option.RCVBUF if receive else linux.Socket_Option.SNDBUF
	return linux.setsockopt_sock(linux.Fd(sock), .SOCKET, opt, &value) == .NONE
}
