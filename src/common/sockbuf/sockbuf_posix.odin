#+build darwin, openbsd, freebsd, netbsd
package sockbuf

import "core:net"
import "core:sys/posix"

@(private)
_set_buffer_size :: proc(sock: net.Socket, receive: bool, bytes: int) -> bool {
	value := i32(min(bytes, int(max(i32))))
	opt := posix.Sock_Option.RCVBUF if receive else posix.Sock_Option.SNDBUF
	return posix.setsockopt(posix.FD(sock), posix.SOL_SOCKET, opt, &value, size_of(value)) == .OK
}
